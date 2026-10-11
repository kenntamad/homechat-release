// Moves encrypted packets between devices on a frequency, by every route at
// once: public relays (works anywhere) and direct Wi-Fi (works without
// internet). Duplicates are dropped by packet id.
//
// Catching up:
//  - Relays keep stored packets for 7 days, so a device that was off for less
//    than a week just reads them back.
//  - Longer gaps are filled from other devices: over Wi-Fi when they meet, or
//    over the relays by asking ("syncreq") and letting an online device answer.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/e2e.dart' show randomBytes;
import '../crypto/frequency.dart';
import '../crypto/schnorr.dart';
import '../data/store.dart';
import 'lan.dart';
import 'nostr.dart';

const relayRetention = Duration(days: 7);
const chunkBytes = 24 * 1024;
const maxRelayFileBytes = 8 * 1024 * 1024;

String newId() => hexOf(randomBytes(16));

class Transport {
  Transport({
    required this.channel,
    required this.store,
    required this.nostrKey,
    required this.deviceId,
    required this.userId,
    required List<String> relayUrls,
    required this.onInner,
    this.onStatus,
    this.lanSyncMarks,
    List<Map<String, dynamic>>? outbox,
    this.onOutboxChanged,
  }) {
    if (outbox != null) _outbox.addAll(outbox);
    relays = RelayPool(urls: relayUrls, tag: channel.tag, onContent: (p, stored) => receive(p, live: !stored), onStatus: _status);
    lan = Lan(
      channel: channel,
      deviceId: deviceId,
      userId: userId,
      onPacket: (p) => receive(p, live: true),
      syncSource: (since, limit) => store.since(since, limit),
      blobSource: _blobForPeer,
      onPeerFound: _syncWithPeer,
      onChange: _status,
    );
  }

  final Channel channel;
  final Store store;
  final NostrKey nostrKey;
  final String deviceId;
  final String userId;

  /// Every decrypted packet (other than transport plumbing). [live] is false for history/catch-up.
  final void Function(Map<String, dynamic> inner, bool live) onInner;
  final void Function()? onStatus;

  /// Remembers when we last caught up with each Wi-Fi device (deviceId -> ms).
  final Map<String, int>? lanSyncMarks;

  late final RelayPool relays;
  late final Lan lan;

  /// Signed events no relay has taken yet (we were offline). Sent on reconnect.
  final List<Map<String, dynamic>> _outbox = [];
  final void Function(List<Map<String, dynamic>> outbox)? onOutboxChanged;
  bool get hasUnsent => _outbox.isNotEmpty;

  final Set<String> _seenEphemeral = {};
  final Set<String> _answeredSync = {};
  final Map<String, List<Uint8List?>> _chunks = {};
  final Map<String, List<Completer<Uint8List?>>> _blobWaiters = {};
  Timer? _syncTimer;

  bool get online => relays.anyConnected || lan.freshPeers.isNotEmpty;
  int get relayCount => relays.status.where((s) => s.connected).length;

  Future<void> start() async {
    relays.since = () {
      final weekAgo = DateTime.now().subtract(relayRetention).millisecondsSinceEpoch ~/ 1000;
      return weekAgo;
    };
    relays.start();
    await lan.start();
    // Once relays have had time to replay the last week, check for older gaps.
    _syncTimer = Timer(const Duration(seconds: 15), _maybeAskForSync);
  }

  Future<void> stop() async {
    _syncTimer?.cancel();
    relays.stop();
    await lan.stop();
  }

  void kick() => relays.kick();

  void _status() {
    if (_outbox.isNotEmpty && relays.anyConnected) {
      final pending = List<Map<String, dynamic>>.from(_outbox);
      _outbox.clear();
      for (final ev in pending) {
        if (relays.publish(ev) == 0) _outbox.add(ev);
      }
      onOutboxChanged?.call(_outbox);
    }
    onStatus?.call();
  }

  // ------------------------------------------------------------------ send
  /// Encrypt and send. Stored packets are kept on relays (up to [ttl], max 7 days)
  /// and in this device's history; ephemeral ones are only delivered live.
  /// Returns true if it reached at least one relay or Wi-Fi device right away
  /// (stored packets that didn't are queued and sent on reconnect).
  Future<bool> publish(Map<String, dynamic> inner, {bool ephemeral = false, Duration? ttl}) async {
    inner['i'] ??= newId();
    inner['t'] ??= DateTime.now().millisecondsSinceEpoch;
    inner['f'] ??= userId;
    inner['d'] ??= deviceId;
    if (ephemeral) inner['e'] = 1;
    final packet = await channel.seal(inner);
    final id = inner['i'] as String;
    if (ephemeral) {
      _seenEphemeral.add(id);
    } else if (inner['k'] != 'chunk') {
      store.add(id, inner['t'] as int, packet);
    }
    lan.broadcast(packet);
    final keep = (ttl == null || ttl > relayRetention) ? relayRetention : ttl!;
    final expires = DateTime.now().add(keep).millisecondsSinceEpoch ~/ 1000;
    final tags = [
      ['t', channel.tag],
      if (!ephemeral) ['expiration', '$expires'],
    ];
    final event = await _sign(nostrKey, ephemeral ? kindEphemeral : kindStored, tags, packet);
    final reached = relays.publish(event);
    if (reached == 0 && !ephemeral && inner['k'] != 'chunk') {
      _outbox.add(event);
      if (_outbox.length > 2000) _outbox.removeAt(0);
      onOutboxChanged?.call(_outbox);
    }
    return reached > 0 || lan.freshPeers.isNotEmpty;
  }

  // Static so the isolate closure captures only these values (not the Transport).
  static Future<Map<String, dynamic>> _sign(NostrKey key, int kind, List<List<String>> tags, String content) =>
      Isolate.run(() => buildNostrEvent(key, kind: kind, tags: tags, content: content));

  // ------------------------------------------------------------------ receive
  Future<void> receive(String packet, {required bool live}) async {
    final inner = await channel.open(packet);
    if (inner == null) return;
    final id = inner['i'];
    if (id is! String || inner['t'] is! int) return;
    final ephemeral = inner['e'] == 1;
    if (ephemeral) {
      if (!_seenEphemeral.add(id)) return;
      if (_seenEphemeral.length > 5000) _seenEphemeral.clear();
    } else {
      if (store.has(id)) return;
    }
    switch (inner['k']) {
      case 'chunk':
        await _onChunk(inner);
        return;
      case 'syncreq':
        _onSyncRequest(inner);
        return;
      case 'syncrep':
        _answeredSync.add(inner['r'] as String? ?? '');
        if (inner['to'] == userId || inner['to'] == null) {
          for (final p in (inner['p'] as List? ?? const [])) {
            if (p is String) await receive(p, live: false);
          }
        }
        return;
    }
    if (!ephemeral) store.add(id, inner['t'] as int, packet);
    onInner(inner, live);
  }

  // ------------------------------------------------------------------ files
  static String blobIdOf(Uint8List encrypted) => hexOf(c.sha256.convert(encrypted).bytes).substring(0, 32);

  /// Keep an encrypted attachment and send it out. Small enough files also go through
  /// the relays in pieces; bigger ones are fetched directly over Wi-Fi.
  Future<bool> sendBlob(String blobId, Uint8List encrypted, {Duration? ttl}) async {
    await store.putBlob(blobId, encrypted);
    _checkedBlobs.add(blobId);
    _haveBlobs.add(blobId);
    if (encrypted.length > maxRelayFileBytes) return false;
    final total = (encrypted.length / chunkBytes).ceil();
    unawaited(() async {
      for (var n = 0; n < total; n++) {
        final part = encrypted.sublist(n * chunkBytes, min((n + 1) * chunkBytes, encrypted.length));
        await publish({'k': 'chunk', 'b': blobId, 'n': n, 'of': total, 'x': base64.encode(part)}, ttl: ttl);
        // Be polite to the public relays.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }());
    return true;
  }

  final Set<String> _checkedBlobs = {};
  final Set<String> _haveBlobs = {};

  Future<void> _onChunk(Map<String, dynamic> m) async {
    final id = m['b'] as String? ?? '';
    final n = (m['n'] as num?)?.toInt() ?? -1;
    final total = (m['of'] as num?)?.toInt() ?? 0;
    if (!Store.validBlobId(id) || total <= 0 || total > 1000 || n < 0 || n >= total) return;
    // Relays replay the week's pieces on every start; skip files we already have.
    if (_checkedBlobs.add(id) && await store.hasBlob(id)) _haveBlobs.add(id);
    if (_haveBlobs.contains(id)) return;
    final parts = _chunks.putIfAbsent(id, () => List<Uint8List?>.filled(total, null));
    if (parts.length != total) return;
    parts[n] = base64.decode(m['x'] as String);
    if (parts.any((p) => p == null)) return;
    _chunks.remove(id);
    final whole = Uint8List.fromList([for (final p in parts) ...p!]);
    if (blobIdOf(whole) != id) return;
    _haveBlobs.add(id);
    await store.putBlob(id, whole);
    _resolveBlob(id, whole);
  }

  void _resolveBlob(String id, Uint8List? bytes) {
    for (final w in _blobWaiters.remove(id) ?? const <Completer<Uint8List?>>[]) {
      if (!w.isCompleted) w.complete(bytes);
    }
  }

  Future<Uint8List?> _blobForPeer(String id) => store.getBlob(id);

  /// Encrypted attachment bytes: from this device, a device on the Wi-Fi, or (wait for) relay pieces.
  Future<Uint8List?> getBlob(String id, {Duration wait = const Duration(seconds: 90)}) async {
    final local = await store.getBlob(id);
    if (local != null) return local;
    final fromLan = await lan.fetchBlob(id);
    if (fromLan != null && blobIdOf(fromLan) == id) {
      await store.putBlob(id, fromLan);
      return fromLan;
    }
    final w = Completer<Uint8List?>();
    _blobWaiters.putIfAbsent(id, () => []).add(w);
    return w.future.timeout(wait, onTimeout: () => null);
  }

  // ------------------------------------------------------------------ catching up
  Future<void> _syncWithPeer(LanPeer peer) async {
    final mark = lanSyncMarks?[peer.deviceId] ?? 0;
    try {
      final packets = await lan.pull(peer, mark);
      for (final p in packets) {
        await receive(p, live: false);
      }
      lanSyncMarks?[peer.deviceId] = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
      peer.lastSync = DateTime.now();
    } catch (_) {}
  }

  void _maybeAskForSync() {
    final newest = store.newestTs;
    final gapStart = DateTime.now().subtract(relayRetention - const Duration(hours: 12)).millisecondsSinceEpoch;
    // We've been here before, but our newest packet is older than the relays remember.
    if (newest == 0 || newest > gapStart) return;
    publish({'k': 'syncreq', 's': newest, 'r': newId()}, ephemeral: true);
  }

  void _onSyncRequest(Map<String, dynamic> m) {
    if (m['d'] == deviceId) return;
    final reqId = m['r'] as String? ?? '';
    final since = (m['s'] as num?)?.toInt() ?? 0;
    final requester = m['f'] as String?;
    // Wait a moment so only one online device answers.
    Timer(Duration(milliseconds: 500 + Random().nextInt(4000)), () async {
      if (_answeredSync.contains(reqId)) return;
      _answeredSync.add(reqId);
      final cutoff = DateTime.now().subtract(relayRetention - const Duration(hours: 12)).millisecondsSinceEpoch;
      final missing = store.all.where((p) => p.ts > since && p.ts < cutoff).toList();
      var batch = <String>[];
      var size = 0;
      Future<void> flush() async {
        if (batch.isEmpty) return;
        await publish({'k': 'syncrep', 'r': reqId, 'to': requester, 'p': batch}, ephemeral: true);
        batch = [];
        size = 0;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      for (final p in missing.take(3000)) {
        batch.add(p.packet);
        size += p.packet.length;
        if (size > 36 * 1024) await flush();
      }
      await flush();
    });
  }
}
