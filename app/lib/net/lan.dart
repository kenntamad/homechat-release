// Direct device-to-device on the same Wi-Fi: no internet needed.
//
// Every few seconds each device broadcasts a tiny encrypted "I'm here on this
// frequency" beacon over UDP. Devices that can decrypt it (same frequency)
// talk to each other over a small HTTP server each device runs:
//   POST /hc/<tag>/p            deliver a packet
//   GET  /hc/<tag>/sync?since=  stored packets newer than `since` (for catching up)
//   GET  /hc/<tag>/blob/<id>    an encrypted attachment
// Everything on the wire is encrypted with the frequency key (packets) or the
// file's own key (blobs), so the endpoints need no further authentication.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../crypto/frequency.dart';

const lanPort = 45454;

class LanPeer {
  LanPeer({required this.deviceId, required this.userId, required this.address, required this.port});
  final String deviceId;
  String userId;
  InternetAddress address;
  int port;
  DateTime lastSeen = DateTime.now();
  DateTime? lastSync;

  bool get fresh => DateTime.now().difference(lastSeen).inSeconds < 20;
  String get base => 'http://${address.address}:$port';
}

class Lan {
  Lan({
    required this.channel,
    required this.deviceId,
    required this.userId,
    required this.onPacket,
    required this.syncSource,
    required this.blobSource,
    required this.onPeerFound,
    this.onChange,
  });

  final Channel channel;
  final String deviceId;
  final String userId;

  /// Incoming packet (encrypted with the frequency key).
  final void Function(String packet) onPacket;

  /// Stored packets newer than a time (ms), oldest first: {'t': ms, 'p': packet}.
  final List<Map<String, dynamic>> Function(int since, int limit) syncSource;

  /// Encrypted attachment bytes, if this device has it.
  final Future<Uint8List?> Function(String blobId) blobSource;

  /// A device on this frequency appeared on the network (time to catch up).
  final void Function(LanPeer peer) onPeerFound;
  final void Function()? onChange;

  final Map<String, LanPeer> peers = {};
  HttpServer? _server;
  RawDatagramSocket? _udp;
  Timer? _beacon;
  final http.Client _http = http.Client();
  String? error;

  String get _prefix => '/hc/${channel.tag}';
  List<LanPeer> get freshPeers => peers.values.where((p) => p.fresh).toList();

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server!.listen(_handle, onError: (_) {});
    } catch (e) {
      error = 'Wi-Fi direct unavailable: $e';
      return;
    }
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, lanPort, reuseAddress: true);
      _udp!.broadcastEnabled = true;
      _udp!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = _udp?.receive();
        if (d != null) _onBeacon(d);
      });
    } catch (e) {
      error = 'Wi-Fi discovery unavailable: $e';
    }
    _beacon = Timer.periodic(const Duration(seconds: 5), (_) => _sendBeacon());
    _sendBeacon();
  }

  Future<void> stop() async {
    _beacon?.cancel();
    _udp?.close();
    _udp = null;
    await _server?.close(force: true);
    _server = null;
    peers.clear();
  }

  // ------------------------------------------------------------------ discovery
  Future<void> _sendBeacon() async {
    final udp = _udp;
    final server = _server;
    if (udp == null || server == null) return;
    final body = await channel.seal({'k': 'lan', 'd': deviceId, 'u': userId, 'p': server.port});
    final bytes = utf8.encode('${channel.tag.substring(0, 8)}:$body');
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          final o = a.rawAddress;
          if (o.length == 4 && !a.isLoopback) targets.add(InternetAddress.fromRawAddress(Uint8List.fromList([o[0], o[1], o[2], 255])));
        }
      }
    } catch (_) {}
    for (final t in targets) {
      try {
        udp.send(bytes, t, lanPort);
      } catch (_) {}
    }
    // Forget devices that went quiet.
    final before = peers.length;
    peers.removeWhere((_, p) => DateTime.now().difference(p.lastSeen).inMinutes >= 2);
    if (peers.length != before) onChange?.call();
  }

  Future<void> _onBeacon(Datagram d) async {
    final text = utf8.decode(d.data, allowMalformed: true);
    final cut = text.indexOf(':');
    if (cut != 8 || text.substring(0, 8) != channel.tag.substring(0, 8)) return;
    final m = await channel.open(text.substring(9));
    if (m == null || m['k'] != 'lan' || m['d'] == deviceId) return;
    final id = m['d'] as String;
    final port = (m['p'] as num).toInt();
    final existing = peers[id];
    if (existing != null) {
      existing
        ..lastSeen = DateTime.now()
        ..address = d.address
        ..port = port;
      return;
    }
    final peer = LanPeer(deviceId: id, userId: m['u'] as String, address: d.address, port: port);
    peers[id] = peer;
    onChange?.call();
    onPeerFound(peer);
  }

  // ------------------------------------------------------------------ server
  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (!path.startsWith('$_prefix/')) {
        res.statusCode = 404;
        return await res.close();
      }
      final rest = path.substring(_prefix.length + 1);
      if (req.method == 'POST' && rest == 'p') {
        final body = await utf8.decodeStream(req);
        if (body.length < 4 * 1024 * 1024) onPacket(body);
        res.statusCode = 204;
      } else if (req.method == 'GET' && rest == 'sync') {
        final since = int.tryParse(req.uri.queryParameters['since'] ?? '') ?? 0;
        final list = syncSource(since, 300);
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'packets': list, 'more': list.length >= 300}));
      } else if (req.method == 'GET' && rest.startsWith('blob/')) {
        final bytes = await blobSource(rest.substring(5));
        if (bytes == null) {
          res.statusCode = 404;
        } else {
          res.headers.contentType = ContentType.binary;
          res.contentLength = bytes.length;
          res.add(bytes);
        }
      } else {
        res.statusCode = 404;
      }
    } catch (_) {
      res.statusCode = 500;
    }
    await res.close();
  }

  // ------------------------------------------------------------------ client
  /// Send a packet straight to every device on the Wi-Fi. Fire and forget.
  void broadcast(String packet) {
    for (final p in freshPeers) {
      _http
          .post(Uri.parse('${p.base}$_prefix/p'), body: packet)
          .timeout(const Duration(seconds: 4))
          .catchError((_) => http.Response('', 599));
    }
  }

  /// Fetch everything a peer has that is newer than [since] (ms).
  Future<List<String>> pull(LanPeer p, int since) async {
    final out = <String>[];
    var cursor = since;
    for (var page = 0; page < 200; page++) {
      final r = await _http.get(Uri.parse('${p.base}$_prefix/sync?since=$cursor')).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) break;
      final m = jsonDecode(r.body) as Map;
      final list = (m['packets'] as List).cast<Map>();
      for (final x in list) {
        out.add(x['p'] as String);
        final t = (x['t'] as num).toInt();
        if (t > cursor) cursor = t;
      }
      if (m['more'] != true || list.isEmpty) break;
    }
    return out;
  }

  Future<Uint8List?> fetchBlob(String blobId) async {
    for (final p in freshPeers) {
      try {
        final r = await _http.get(Uri.parse('${p.base}$_prefix/blob/$blobId')).timeout(const Duration(minutes: 5));
        if (r.statusCode == 200) return r.bodyBytes;
      } catch (_) {}
    }
    return null;
  }
}
