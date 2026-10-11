// BIP-340 Schnorr signatures over secp256k1, the signature scheme Nostr relays
// require on every event. Small pure-Dart implementation (signing only needs to
// be fast enough for a few events per second).
//
// Checked against the official BIP-340 test vectors in test/schnorr_test.dart.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

final BigInt _p = BigInt.parse('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F', radix: 16);
final BigInt _n = BigInt.parse('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141', radix: 16);
final _G = _Pt(
  BigInt.parse('79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798', radix: 16),
  BigInt.parse('483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8', radix: 16),
);

class _Pt {
  const _Pt(this.x, this.y);
  final BigInt x, y;
}

BigInt _mod(BigInt a, [BigInt? m]) {
  final mm = m ?? _p;
  final r = a % mm; // Dart's % is always non-negative for positive modulus
  return r;
}

_Pt? _add(_Pt? a, _Pt? b) {
  if (a == null) return b;
  if (b == null) return a;
  if (a.x == b.x && a.y != b.y) return null;
  BigInt l;
  if (a.x == b.x) {
    l = _mod(BigInt.from(3) * a.x * a.x * (BigInt.two * a.y).modInverse(_p));
  } else {
    l = _mod((b.y - a.y) * _mod(b.x - a.x).modInverse(_p));
  }
  final x = _mod(l * l - a.x - b.x);
  return _Pt(x, _mod(l * (a.x - x) - a.y));
}

_Pt? _mul(BigInt k, [_Pt? pt]) {
  final base = pt ?? _G;
  _Pt? r;
  for (var i = 255; i >= 0; i--) {
    r = _add(r, r);
    if ((k >> i) & BigInt.one == BigInt.one) r = _add(r, base);
  }
  return r;
}

Uint8List _b32(BigInt x) {
  final hex = x.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

BigInt _int(List<int> b) => BigInt.parse(b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(), radix: 16);

Uint8List _sha(List<int> b) => Uint8List.fromList(c.sha256.convert(b).bytes);

Uint8List _tagged(String tag, List<List<int>> parts) {
  final t = _sha(tag.codeUnits);
  return _sha([...t, ...t, for (final p in parts) ...p]);
}

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List bytesOfHex(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// A secp256k1 key for signing relay events.
class NostrKey {
  NostrKey(List<int> secret32) : _d = _mod(_int(secret32), _n) {
    if (_d == BigInt.zero) throw ArgumentError('invalid key');
    final p = _mul(_d)!;
    publicKeyHex = hexOf(_b32(p.x));
    _evenY = p.y.isEven;
  }

  final BigInt _d;
  late final String publicKeyHex;
  late final bool _evenY;

  /// BIP-340 signature of a 32-byte message. [aux] is 32 random bytes.
  Uint8List sign(List<int> msg32, List<int> aux) {
    final d = _evenY ? _d : _n - _d;
    final auxHash = _tagged('BIP0340/aux', [aux]);
    final db = _b32(d);
    final t = [for (var i = 0; i < 32; i++) db[i] ^ auxHash[i]];
    final pk = bytesOfHex(publicKeyHex);
    final k0 = _mod(_int(_tagged('BIP0340/nonce', [t, pk, msg32])), _n);
    if (k0 == BigInt.zero) throw StateError('bad nonce');
    final r = _mul(k0)!;
    final k = r.y.isEven ? k0 : _n - k0;
    final rx = _b32(r.x);
    final e = _mod(_int(_tagged('BIP0340/challenge', [rx, pk, msg32])), _n);
    return Uint8List.fromList([...rx, ..._b32(_mod(k + e * d, _n))]);
  }
}

/// Verify a BIP-340 signature (used by tests; relays verify for us).
bool schnorrVerify(List<int> pubkey32, List<int> msg32, List<int> sig64) {
  final x = _int(pubkey32);
  if (x >= _p) return false;
  final y2 = _mod(x.modPow(BigInt.from(3), _p) + BigInt.from(7));
  var y = y2.modPow((_p + BigInt.one) >> 2, _p);
  if (_mod(y * y) != y2) return false;
  if (y.isOdd) y = _p - y;
  final r = _int(sig64.sublist(0, 32));
  final s = _int(sig64.sublist(32));
  if (r >= _p || s >= _n) return false;
  final e = _mod(_int(_tagged('BIP0340/challenge', [sig64.sublist(0, 32), pubkey32, msg32])), _n);
  final rr = _add(_mul(s), _mul(_n - e, _Pt(x, y)));
  return rr != null && rr.y.isEven && rr.x == r;
}
