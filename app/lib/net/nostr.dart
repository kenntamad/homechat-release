// Minimal Nostr relay pool. Relays are public servers run by volunteers; we
// only use them as dumb mailboxes for packets that are already encrypted with
// the frequency key. Events are tagged with the frequency's public tag so
// everyone on the same frequency can find them.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as c;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/e2e.dart' show randomBytes;
import '../crypto/schnorr.dart';

/// Stored events (messages, receipts, profiles, file chunks). Relays keep them.
const kindStored = 4747;

/// Ephemeral events (typing, presence, call signaling, sync). Relays forward only.
const kindEphemeral = 24747;

Map<String, dynamic> buildNostrEvent(
  NostrKey key, {
  required int kind,
  required List<List<String>> tags,
  required String content,
  int? createdAt,
  List<int>? aux,
}) {
  final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final serialized = jsonEncode([0, key.publicKeyHex, ts, kind, tags, content]);
  final id = c.sha256.convert(utf8.encode(serialized)).bytes;
  final sig = key.sign(id, aux ?? randomBytes(32));
  return {
    'id': hexOf(id),
    'pubkey': key.publicKeyHex,
    'created_at': ts,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': hexOf(sig),
  };
}

class RelayStatus {
  RelayStatus(this.url);
  final String url;
  bool connected = false;
  String? lastError;
  int received = 0;
}

/// Keeps a connection to every relay, one subscription for our frequency tag,
/// and publishes to all of them.
class RelayPool {
  RelayPool({required this.urls, required this.tag, required this.onContent, this.onStatus});

  final List<String> urls;
  final String tag;

  /// Called with the event content (an encrypted packet) and whether it came from history.
  final void Function(String content, bool stored) onContent;
  final void Function()? onStatus;

  final Map<String, _Relay> _relays = {};
  final Set<String> _seenEventIds = {};
  bool _stopped = false;

  /// Unix seconds: fetch stored events since this time on (re)connect.
  int Function() since = () => DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7 * 86400;

  List<RelayStatus> get status => [for (final r in _relays.values) r.status];
  bool get anyConnected => _relays.values.any((r) => r.status.connected);

  void start() {
    _stopped = false;
    for (final u in urls) {
      _relays[u] = _Relay(u, this)..connect();
    }
  }

  void stop() {
    _stopped = true;
    for (final r in _relays.values) {
      r.close();
    }
    _relays.clear();
  }

  void kick() {
    for (final r in _relays.values) {
      if (!r.status.connected) r.connect(now: true);
    }
  }

  /// Send an already-built event to every connected relay. Returns how many took it.
  int publish(Map<String, dynamic> event) {
    _seenEventIds.add(event['id'] as String);
    var n = 0;
    final msg = jsonEncode(['EVENT', event]);
    for (final r in _relays.values) {
      if (r.send(msg)) n++;
    }
    return n;
  }

  void _onEvent(Map<String, dynamic> ev, bool stored) {
    final id = ev['id'];
    if (id is! String || !_seenEventIds.add(id)) return;
    if (_seenEventIds.length > 20000) _seenEventIds.clear();
    final content = ev['content'];
    if (content is String && content.isNotEmpty) onContent(content, stored);
  }
}

class _Relay {
  _Relay(this.url, this.pool) : status = RelayStatus(url);

  final String url;
  final RelayPool pool;
  final RelayStatus status;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _retry;
  Timer? _ping;
  int _attempt = 0;
  final String _subId = 'hc${hexOf(randomBytes(4))}';
  bool _historyDone = false;

  bool send(String msg) {
    if (!status.connected) return false;
    try {
      _ch?.sink.add(msg);
      return true;
    } catch (_) {
      return false;
    }
  }

  void connect({bool now = false}) {
    if (pool._stopped) return;
    _retry?.cancel();
    if (now) _attempt = 0;
    _open();
  }

  Future<void> _open() async {
    _sub?.cancel();
    try {
      final ch = WebSocketChannel.connect(Uri.parse(url));
      _ch = ch;
      await ch.ready.timeout(const Duration(seconds: 12));
      if (pool._stopped || _ch != ch) {
        ch.sink.close();
        return;
      }
      status
        ..connected = true
        ..lastError = null;
      _attempt = 0;
      _historyDone = false;
      pool.onStatus?.call();
      _sub = ch.stream.listen(_onData, onDone: _lost, onError: (e) {
        status.lastError = '$e';
        _lost();
      }, cancelOnError: true);
      ch.sink.add(jsonEncode([
        'REQ',
        _subId,
        {
          'kinds': [kindStored, kindEphemeral],
          '#t': [pool.tag],
          'since': pool.since(),
        },
      ]));
      // Some relays drop idle sockets; a harmless no-op keeps them busy.
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 50), (_) => send(jsonEncode(['REQ', '${_subId}p', {'ids': ['0' * 64], 'limit': 1}])));
    } catch (e) {
      status.lastError = '$e';
      _lost();
    }
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    List msg;
    try {
      msg = jsonDecode(data) as List;
    } catch (_) {
      return;
    }
    if (msg.isEmpty) return;
    switch (msg[0]) {
      case 'EVENT':
        if (msg.length >= 3 && msg[1] == _subId && msg[2] is Map) {
          status.received++;
          pool._onEvent((msg[2] as Map).cast<String, dynamic>(), !_historyDone);
        }
      case 'EOSE':
        if (msg.length >= 2 && msg[1] == _subId) _historyDone = true;
      case 'CLOSED':
        if (msg.length >= 2 && msg[1] == _subId) {
          status.lastError = msg.length > 2 ? '${msg[2]}' : 'closed by relay';
          _lost();
        }
      case 'OK':
        if (msg.length >= 4 && msg[2] == false) status.lastError = '${msg[3]}';
      case 'NOTICE':
        if (msg.length >= 2) status.lastError = '${msg[1]}';
    }
  }

  void _lost() {
    _ping?.cancel();
    final was = status.connected;
    status.connected = false;
    _ch?.sink.close();
    _ch = null;
    if (was) pool.onStatus?.call();
    if (pool._stopped) return;
    _retry?.cancel();
    final delay = min(120, pow(2, _attempt).toInt() * 2) + Random().nextInt(3);
    _attempt++;
    _retry = Timer(Duration(seconds: delay), _open);
  }

  void close() {
    _retry?.cancel();
    _ping?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    status.connected = false;
  }
}
