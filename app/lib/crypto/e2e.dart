// End-to-end encryption for Home Chat.
//
// Must stay byte-compatible with server/test/e2e.js (the reference used by
// the server test-suite):
//
//   master  = PBKDF2-HMAC-SHA256(password, "homechat:v1:<username lowercased>", 100000, 32)
//   auth    = HKDF-SHA256(master, salt: empty, info: "homechat auth")   -> sent to server
//   wrapKey = HKDF-SHA256(master, salt: empty, info: "homechat key")    -> never leaves the device
//   encPrivateKey = base64(nonce12 || AES-256-GCM(wrapKey, x25519 seed) || tag16)
//
// Message envelope {v:1, s, n, c, k}:
//   contentKey random 32 bytes; c = AES-GCM(contentKey, n, utf8(json(payload)))
//   k[userId] = base64(nonce12 || AES-GCM(HKDF(X25519(myPriv, theirPub), "homechat wrap v1"), contentKey))
//   s = sender's public key, so receivers know which key was used.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _rng = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

Future<Uint8List> _hkdfBytes(List<int> ikm, String info) async {
  final key = await _hkdf.deriveKey(secretKey: SecretKey(ikm), nonce: const <int>[], info: utf8.encode(info));
  return Uint8List.fromList(await key.extractBytes());
}

/// AES-256-GCM. Returns ciphertext || tag (16 bytes).
Future<Uint8List> aesEncrypt(List<int> key, List<int> nonce, List<int> plain) async {
  final box = await _aes.encrypt(plain, secretKey: SecretKey(key), nonce: nonce);
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

/// Inverse of [aesEncrypt]. Throws if the data was tampered with or the key is wrong.
Future<Uint8List> aesDecrypt(List<int> key, List<int> nonce, List<int> ctWithTag) async {
  if (ctWithTag.length < 16) throw const FormatException('ciphertext too short');
  final ct = ctWithTag.sublist(0, ctWithTag.length - 16);
  final tag = ctWithTag.sublist(ctWithTag.length - 16);
  final plain = await _aes.decrypt(SecretBox(ct, nonce: nonce, mac: Mac(tag)), secretKey: SecretKey(key));
  return Uint8List.fromList(plain);
}

class PasswordKeys {
  PasswordKeys(this.auth, this.wrapKey);
  final String auth; // base64
  final Uint8List wrapKey;
}

Future<PasswordKeys> _derive(List<String> args) async {
  final username = args[0], password = args[1];
  final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256);
  final master = await pbkdf2.deriveKeyFromPassword(
    password: password,
    nonce: utf8.encode('homechat:v1:${username.toLowerCase()}'),
  );
  final m = await master.extractBytes();
  return PasswordKeys(base64.encode(await _hkdfBytes(m, 'homechat auth')), await _hkdfBytes(m, 'homechat key'));
}

/// Slow on purpose (stretches the password); runs off the UI thread.
Future<PasswordKeys> derivePasswordKeys(String username, String password) {
  return Isolate.run(() => _derive([username, password]));
}

class Identity {
  Identity._(this.seed, this.keyPair, this.publicKey);

  final Uint8List seed;
  final SimpleKeyPair keyPair;
  final String publicKey; // base64 raw 32 bytes

  static Future<Identity> fromSeed(List<int> seed) async {
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return Identity._(Uint8List.fromList(seed), kp, base64.encode(pub.bytes));
  }

  static Future<Identity> generate() => fromSeed(randomBytes(32));

  /// Protect the private key with the password-derived wrap key.
  Future<String> exportEncrypted(Uint8List wrapKey) async {
    final nonce = randomBytes(12);
    final ct = await aesEncrypt(wrapKey, nonce, seed);
    return base64.encode([...nonce, ...ct]);
  }

  static Future<Identity> unlock(String encPrivateKey, Uint8List wrapKey) async {
    final raw = base64.decode(encPrivateKey);
    final seed = await aesDecrypt(wrapKey, raw.sublist(0, 12), raw.sublist(12));
    return fromSeed(seed);
  }

  String get fingerprint {
    // Short, human-comparable form of the public key (for "verify" screens).
    final b = base64.decode(publicKey);
    final hex = b.take(10).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ').toUpperCase();
  }

  final Map<String, Uint8List> _kekCache = {};

  Future<Uint8List> _kek(String theirPublicKey) async {
    final cached = _kekCache[theirPublicKey];
    if (cached != null) return cached;
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(base64.decode(theirPublicKey), type: KeyPairType.x25519),
    );
    final kek = await _hkdfBytes(await shared.extractBytes(), 'homechat wrap v1');
    _kekCache[theirPublicKey] = kek;
    return kek;
  }

  /// Encrypt [payload] for every recipient. recipients: userId -> public key (base64).
  Future<Map<String, dynamic>> seal(Map<String, String> recipients, Map<String, dynamic> payload) async {
    final contentKey = randomBytes(32);
    final nonce = randomBytes(12);
    final c = await aesEncrypt(contentKey, nonce, utf8.encode(jsonEncode(payload)));
    final k = <String, String>{};
    for (final e in recipients.entries) {
      final wn = randomBytes(12);
      final wrapped = await aesEncrypt(await _kek(e.value), wn, contentKey);
      k[e.key] = base64.encode([...wn, ...wrapped]);
    }
    return {'v': 1, 's': publicKey, 'n': base64.encode(nonce), 'c': base64.encode(c), 'k': k};
  }

  /// Decrypt an envelope addressed to [myUserId]. Returns null if it can't be read
  /// (e.g. it was sent before this person's key was reset).
  Future<Map<String, dynamic>?> open(String myUserId, Map<String, dynamic> envelope) async {
    try {
      final wrapped = envelope['k']?[myUserId];
      if (wrapped is! String) return null;
      final w = base64.decode(wrapped);
      final contentKey = await aesDecrypt(await _kek(envelope['s'] as String), w.sublist(0, 12), w.sublist(12));
      final plain = await aesDecrypt(contentKey, base64.decode(envelope['n'] as String), base64.decode(envelope['c'] as String));
      return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

/// Encrypted attachment: (key, nonce, ciphertext). Big files are processed off the UI thread.
class SealedFile {
  SealedFile(this.key, this.nonce, this.data);
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List data;
}

Future<SealedFile> sealFile(Uint8List plain) async {
  final key = randomBytes(32);
  final nonce = randomBytes(12);
  final data = plain.length > 512 * 1024
      ? await Isolate.run(() => aesEncrypt(key, nonce, plain))
      : await aesEncrypt(key, nonce, plain);
  return SealedFile(key, nonce, data);
}

Future<Uint8List> openFile(Uint8List data, String keyB64, String nonceB64) async {
  final key = base64.decode(keyB64);
  final nonce = base64.decode(nonceB64);
  return data.length > 512 * 1024
      ? Isolate.run(() => aesDecrypt(key, nonce, data))
      : aesDecrypt(key, nonce, data);
}
