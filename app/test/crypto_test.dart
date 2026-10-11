// Proves the Flutter app's encryption is byte-compatible with the server's
// reference implementation (server/test/e2e.js). Vectors were produced there.
//   flutter test
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homechat/crypto/e2e.dart';

const momSeed = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=';
const dadSeed = 'yMfGxcTDwsHAv769vLu6ubi3trW0s7KxsK+urayrqqk=';
const momAuth = 'yHyWieyadin5suW1F+5XrGimXDWRrlMCq7Sgggc9YrE=';
const momPublic = 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=';
const momEncPrivateKey = 'h4t/1c9467qU6Y12DuSIgg0Lg+lpdM2S1G/do9m1/dGBiUbSwUzIQ1hY4XLDrZTy8/6xB6cSA2ijxpC6';
const dadPublic = 'ja/P7q6QRe6aeNeKmfzzLneB5EHrBzCWw0K44tzDthI=';
const envelope = {
  'v': 1,
  's': 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=',
  'n': 'NNL492viRSws+sPZ',
  'c': 'q7a2oeWKat4P6xFrrgzonEo1THL62bxQNSa32juNtWG8XgXOj6qlJTHWzfkPE3IEavLE',
  'k': {
    'mom': 'IRKtj4E+6Q/bY6JupkwD0NkJrsq6ESHf0nyFO7tvzUj9l1rwtOtWXmB9mqsE3lrFKGUWqPM7MeDS4j8v',
    'dad': 'jJRBpP+/uWCGKfV9pluhKeg7IiFgLOexDYeLwfSRepLNza9P6O0pg1OQaHggaKYW5++jBOnbUOSj1sXE',
  },
};

void main() {
  test('password derivation matches the server reference', () async {
    final keys = await derivePasswordKeys('Mom', 'correct horse');
    expect(keys.auth, momAuth);
    final id = await Identity.unlock(momEncPrivateKey, keys.wrapKey);
    expect(base64.encode(id.seed), momSeed);
  });

  test('X25519 public keys match', () async {
    expect((await Identity.fromSeed(base64.decode(momSeed))).publicKey, momPublic);
    expect((await Identity.fromSeed(base64.decode(dadSeed))).publicKey, dadPublic);
  });

  test('opens an envelope sealed by the reference implementation', () async {
    final dad = await Identity.fromSeed(base64.decode(dadSeed));
    final mom = await Identity.fromSeed(base64.decode(momSeed));
    expect((await dad.open('dad', envelope))!['text'], 'Kumusta! 🏠');
    expect((await mom.open('mom', envelope))!['text'], 'Kumusta! 🏠');
    expect(await mom.open('kid', envelope), isNull);
  });

  test('round trip: seal for two people, both can open', () async {
    final mom = await Identity.generate();
    final dad = await Identity.generate();
    final env = await mom.seal({'mom': mom.publicKey, 'dad': dad.publicKey}, {'t': 'text', 'text': 'hi'});
    expect((await dad.open('dad', env))!['text'], 'hi');
    final tampered = Map<String, dynamic>.from(env)..['c'] = base64.encode(base64.decode(env['c']).reversed.toList());
    expect(await dad.open('dad', tampered), isNull);
  });

  test('file encryption round trip', () async {
    final data = utf8.encode('photo bytes' * 1000);
    final sealed = await sealFile(data);
    final back = await openFile(sealed.data, base64.encode(sealed.key), base64.encode(sealed.nonce));
    expect(back, data);
  });
}
