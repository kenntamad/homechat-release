// A "frequency" is the shared secret that puts devices on the same channel,
// like tuning walkie-talkies. Everything sent on it is encrypted with a key
// derived from it, so relays and Wi-Fi neighbours only ever see random bytes.
//
// Must stay byte-compatible with the reference in test/frequency_test.dart:
//   master = PBKDF2-HMAC-SHA256(normalized, "homechat:frequency:v2", 100000, 32)
//   key    = HKDF-SHA256(master, info "homechat channel key", 32)
//   tag    = hex(HKDF-SHA256(master, info "homechat channel tag", 16))  (public lookup id)
//   packet = base64(nonce12 || AES-256-GCM(key, utf8(json)) || tag16)
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

import 'e2e.dart';
import 'schnorr.dart';

String normalizeFrequency(String f) => f.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Rough strength check so people don't pick "101.5" (anyone could guess it).
int frequencyStrength(String f) {
  final n = normalizeFrequency(f);
  var classes = 0;
  if (RegExp(r'[a-z]').hasMatch(n)) classes++;
  if (RegExp(r'[0-9]').hasMatch(n)) classes++;
  if (RegExp(r'[^a-z0-9]').hasMatch(n)) classes++;
  final words = n.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).length;
  final score = n.length + classes * 3 + words * 2;
  if (score >= 30) return 3; // strong
  if (score >= 24) return 2; // ok
  if (score >= 16) return 1; // weak
  return 0; // too easy to guess
}

const _words = [
  'amber', 'anchor', 'apple', 'atlas', 'bamboo', 'basil', 'beacon', 'berry', 'breeze', 'canyon', 'cedar', 'cloud',
  'comet', 'coral', 'cosmos', 'daisy', 'delta', 'ember', 'falcon', 'fern', 'fiesta', 'galaxy', 'garden', 'harbor',
  'island', 'jasmine', 'kettle', 'lagoon', 'lantern', 'lemon', 'lotus', 'mango', 'maple', 'meadow', 'mocha', 'nebula',
  'oasis', 'orbit', 'pepper', 'pearl', 'pixel', 'planet', 'quartz', 'rainbow', 'river', 'rocket', 'saffron', 'sampaguita',
  'sierra', 'sunflower', 'tamarind', 'thunder', 'tulip', 'velvet', 'violet', 'willow', 'zephyr', 'mabuhay', 'bayani', 'ube',
];

/// e.g. "sunflower-743-orbit-218": easy to read out, hard to guess.
String generateFrequency() {
  final r = randomBytes(8);
  String w(int i) => _words[(r[i] << 8 | r[i + 1]) % _words.length];
  String n(int i) => (100 + ((r[i] << 8 | r[i + 1]) % 900)).toString();
  return '${w(0)}-${n(2)}-${w(4)}-${n(6)}';
}

class Channel {
  Channel._(this.frequency, this.key, this.tag);

  final String frequency;
  final Uint8List key;
  final String tag;

  static Future<Channel> derive(String frequency) async {
    final parts = await Isolate.run(() => _derive(normalizeFrequency(frequency)));
    return Channel._(frequency, parts.$1, parts.$2);
  }

  /// Restore without re-running the slow derivation.
  static Channel restore(String frequency, String keyB64, String tag) => Channel._(frequency, base64.decode(keyB64), tag);

  String get keyB64 => base64.encode(key);

  Future<String> seal(Map<String, dynamic> obj) async {
    final nonce = randomBytes(12);
    final ct = await aesEncrypt(key, nonce, utf8.encode(jsonEncode(obj)));
    return base64.encode([...nonce, ...ct]);
  }

  /// Null if it wasn't sealed with this frequency (or was tampered with).
  Future<Map<String, dynamic>?> open(String packet) async {
    try {
      final b = base64.decode(packet);
      if (b.length < 29) return null;
      final plain = await aesDecrypt(key, b.sublist(0, 12), b.sublist(12));
      final v = jsonDecode(utf8.decode(plain));
      return v is Map ? v.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}

Future<(Uint8List, String)> _derive(String normalized) async {
  final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256);
  final master = await (await pbkdf2.deriveKeyFromPassword(
    password: normalized,
    nonce: utf8.encode('homechat:frequency:v2'),
  )).extractBytes();
  final key = await _hkdf(master, 'homechat channel key', 32);
  final tag = await _hkdf(master, 'homechat channel tag', 16);
  return (key, hexOf(tag));
}

Future<Uint8List> _hkdf(List<int> ikm, String info, int len) async {
  final k = await Hkdf(hmac: Hmac.sha256(), outputLength: len)
      .deriveKey(secretKey: SecretKey(ikm), nonce: const <int>[], info: utf8.encode(info));
  return Uint8List.fromList(await k.extractBytes());
}

/// A person's id on every frequency: first 12 bytes of sha256(their X25519 public key).
String userIdOf(String xpubB64) => hexOf(c.sha256.convert(base64.decode(xpubB64)).bytes).substring(0, 24);

/// The relay-signing key for this identity.
Future<NostrKey> nostrKeyFor(Uint8List identitySeed) async => NostrKey(await _hkdf(identitySeed, 'homechat nostr key', 32));
