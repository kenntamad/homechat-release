// Interop vectors produced by the JavaScript reference implementation
// (BIP-340 checked against the official test vectors). Run: flutter test
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homechat/crypto/frequency.dart';
import 'package:homechat/crypto/schnorr.dart';
import 'package:homechat/net/nostr.dart';

void main() {
  test('BIP-340 official vectors', () {
    final v = [
      ['0000000000000000000000000000000000000000000000000000000000000003', 'F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9',
        '0000000000000000000000000000000000000000000000000000000000000000', '0000000000000000000000000000000000000000000000000000000000000000',
        'E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0'],
      ['B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF', 'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
        '0000000000000000000000000000000000000000000000000000000000000001', '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
        '6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A'],
    ];
    for (final x in v) {
      final k = NostrKey(bytesOfHex(x[0]));
      expect(k.publicKeyHex.toUpperCase(), x[1]);
      final sig = k.sign(bytesOfHex(x[3]), bytesOfHex(x[2]));
      expect(hexOf(sig).toUpperCase(), x[4]);
      expect(schnorrVerify(bytesOfHex(x[1]), bytesOfHex(x[3]), sig), isTrue);
    }
  });

  test('frequency derivation and packets match the reference', () async {
    final ch = await Channel.derive('  Sunflower   143.7 Orbit ');
    expect(ch.tag, '014eca0191b6c23d0539cd7a1ea47f54');
    expect(ch.keyB64, 'nNAzUPMmOVdsaQbbWX340v1Z2UL/Mr8WUqzy5QEpkyE=');
    const pkt = 'BwcHBwcHBwcHBwcH47qdox4vbhuPjJjGz40jPkOm2gtrQSzO0+upsR0b0DsS8lStYP/H8RE/j/TWJnZUvkEglHkbinY5H1j2SFlnLkgEA2CailoerFWHXrxnu6llwYHZex1VB2MLj0A/W5n8kj7YSpO9FA==';
    expect((await ch.open(pkt))!['n'], 'Mabuhay 🏠');
    final other = await Channel.derive('sunflower 143.7 orbit!');
    expect(await other.open(pkt), isNull);
    final round = await ch.open(await ch.seal({'x': 1}));
    expect(round!['x'], 1);
  });

  test('user ids and relay events match the reference', () async {
    expect(userIdOf('B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw='), 'aaa8fff703b50b2297f4f6e1');
    final key = await nostrKeyFor(base64.decode(base64.encode(List<int>.generate(32, (i) => i + 1))));
    expect(key.publicKeyHex, 'e5d41dc5b61b3e617835f32e309d79e92495824673010f0213bbf7a61a17368b');
    final ev = buildNostrEvent(
      key,
      kind: 4747,
      tags: [
        ['t', '014eca0191b6c23d0539cd7a1ea47f54'],
        ['expiration', '1760604800'],
      ],
      content: 'BwcHBwcHBwcHBwcH47qdox4vbhuPjJjGz40jPkOm2gtrQSzO0+upsR0b0DsS8lStYP/H8RE/j/TWJnZUvkEglHkbinY5H1j2SFlnLkgEA2CailoerFWHXrxnu6llwYHZex1VB2MLj0A/W5n8kj7YSpO9FA==',
      createdAt: 1760000000,
      aux: List<int>.filled(32, 9),
    );
    expect(ev['id'], 'bcb8c1ccbd4c6842ea418309dfe3c47e2dc5714352c55cc885bbed53d24da5fc');
    expect(ev['sig'],
        '18555ae8cc80975aa4476fa4303278e34af22a2cd7749e84364963a0f1e7dd3a25ebba60d09a6383587bdc7f87449e965e9057acee21b0ffd0aafd73cb1c0633');
  });

  test('generated frequencies are strong', () {
    for (var i = 0; i < 20; i++) {
      expect(frequencyStrength(generateFrequency()), greaterThanOrEqualTo(2));
    }
    expect(frequencyStrength('101.5'), 0);
  });
}
