// Voice/video calls over WebRTC with no server: devices tell each other about
// the call (invite / join / here / leave) through the same encrypted channel as
// messages, then connect directly. Group calls connect everyone to everyone.
//
// Who sends the WebRTC offer between two devices? The one with the smaller
// device id - so exactly one side does, without coordination.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../data/models.dart';
import '../net/transport.dart' show newId;
import '../services/notifications.dart';
import 'app_state.dart';

class CallPeerConn {
  CallPeerConn(this.peerId, this.userId, this.pc, this.renderer);
  final String peerId; // device id
  final String userId;
  final RTCPeerConnection pc;
  final RTCVideoRenderer renderer;
  final List<RTCIceCandidate> pendingCandidates = [];
  bool remoteSet = false;
  bool hasVideo = false;
  bool audioOn = true;
  bool videoOn = true;
  String state = 'connecting';
}

class CallController extends ChangeNotifier {
  CallController(this.app);
  final AppState app;

  CallInfo? incoming;
  CallInfo? active;
  final Map<String, CallPeerConn> peers = {};
  final Map<String, CallInfo> ongoing = {}; // chatId -> call others are in (for "Join" banners)
  final Map<String, DateTime> _ongoingSeen = {};

  MediaStream? localStream;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool _rendererReady = false;
  bool micOn = true;
  bool cameraOn = true;
  bool speakerOn = false;
  bool video = false;
  DateTime? connectedAt;
  String? error;
  Timer? _ticker;
  Timer? _ringTimer;
  Timer? _incomingTimer;
  Timer? _heartbeat;
  Timer? _ongoingSweep;
  bool _answered = false;

  bool get inCall => active != null;
  bool get _iStarted => active?.startedBy == app.me?.id;

  // ------------------------------------------------------------------ actions
  Future<void> start(String chatId, {required bool video}) async {
    if (inCall) return;
    final existing = ongoing[chatId];
    if (existing != null) return join(existing);
    if (!await _openMedia(video)) return;
    this.video = video;
    _answered = false;
    active = CallInfo(id: newId(), chatId: chatId, video: video, startedBy: app.me!.id, participants: const []);
    notifyListeners();
    await _signal({'k': 'invite', 'video': video});
    _startHeartbeat();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      if (active != null && peers.isEmpty) _finish(status: 'missed');
    });
  }

  Future<void> accept() async {
    final call = incoming;
    if (call == null) return;
    if (inCall) await hangUp();
    incoming = null;
    _incomingTimer?.cancel();
    Notifications.cancelCall();
    if (!await _openMedia(call.video)) return;
    video = call.video;
    active = call;
    _answered = true;
    notifyListeners();
    await _signal({'k': 'join'});
    _startHeartbeat();
  }

  Future<void> join(CallInfo call) async {
    incoming = call;
    await accept();
  }

  void decline() {
    final call = incoming;
    if (call == null) return;
    app.sendCallSignal(call.chatId, {'k': 'decline', 'call': call.id, 'video': call.video});
    incoming = null;
    _incomingTimer?.cancel();
    Notifications.cancelCall();
    notifyListeners();
  }

  Future<void> hangUp() async {
    if (active == null) return;
    await _finish(status: _answered || peers.isNotEmpty ? 'completed' : 'cancelled');
  }

  /// Leave the call, tell the others, and (if we started it) note it in the chat.
  Future<void> _finish({required String status}) async {
    final call = active;
    if (call == null) return;
    final started = connectedAt;
    final wasStarter = _iStarted;
    await _signal({'k': 'leave'});
    await _cleanup();
    if (wasStarter) {
      await app.logCall(call.chatId, {
        'video': call.video,
        'status': status,
        'durationMs': started == null ? 0 : DateTime.now().difference(started).inMilliseconds,
      });
    }
    if (status == 'missed') error = 'No answer';
    if (status == 'declined') error = 'Call declined';
    notifyListeners();
  }

  void toggleMic() {
    micOn = !micOn;
    for (final t in localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = micOn;
    }
    _signal({'k': 'media', 'audio': micOn, 'vid': cameraOn && video});
    notifyListeners();
  }

  void toggleCamera() {
    cameraOn = !cameraOn;
    for (final t in localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = cameraOn;
    }
    _signal({'k': 'media', 'audio': micOn, 'vid': cameraOn && video});
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = localStream?.getVideoTracks() ?? [];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    if (Platform.isAndroid || Platform.isIOS) await Helper.setSpeakerphoneOn(speakerOn);
    notifyListeners();
  }

  Future<void> _signal(Map<String, dynamic> payload, {String? toUser}) async {
    final call = active;
    if (call == null) return;
    await app.sendCallSignal(call.chatId, {...payload, 'call': call.id, 'video': call.video, 'by': call.startedBy}, toUser: toUser);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    // Lets latecomers see a "Join" banner and lets others notice if we vanish.
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) => _signal({'k': 'here'}));
  }

  // ------------------------------------------------------------------ media
  Future<bool> _openMedia(bool withVideo) async {
    error = null;
    try {
      if (!_rendererReady) {
        await localRenderer.initialize();
        _rendererReady = true;
      }
      localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
        'video': withVideo
            ? {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
              }
            : false,
      });
      localRenderer.srcObject = localStream;
      micOn = true;
      cameraOn = withVideo;
      speakerOn = withVideo;
      if (Platform.isAndroid || Platform.isIOS) await Helper.setSpeakerphoneOn(speakerOn);
      return true;
    } catch (e) {
      if (withVideo) {
        try {
          localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
          localRenderer.srcObject = localStream;
          cameraOn = false;
          return true;
        } catch (_) {}
      }
      error = 'Microphone not available. Check app permissions.';
      notifyListeners();
      return false;
    }
  }

  Future<CallPeerConn> _peer(String deviceId, String userId) async {
    final existing = peers[deviceId];
    if (existing != null) return existing;
    final pc = await createPeerConnection({'iceServers': app.iceServers, 'sdpSemantics': 'unified-plan'});
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final peer = CallPeerConn(deviceId, userId, pc, renderer);
    peers[deviceId] = peer;
    _ringTimer?.cancel();
    _answered = true;
    for (final track in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(track, localStream!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _signal({
        'k': 'signal',
        'to': deviceId,
        'data': {
          'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
        },
      }, toUser: userId);
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        renderer.srcObject = e.streams.first;
        if (e.track.kind == 'video') peer.hasVideo = true;
        notifyListeners();
      }
    };
    pc.onConnectionState = (s) {
      peer.state = switch (s) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
        RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'reconnecting',
        _ => peer.state,
      };
      if (peer.state == 'connected' && connectedAt == null) {
        connectedAt = DateTime.now();
        _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
      }
      notifyListeners();
    };
    notifyListeners();
    return peer;
  }

  /// A device is in our call: connect to it (the smaller device id makes the offer).
  Future<void> _meet(String deviceId, String userId) async {
    if (deviceId == app.deviceId || peers.containsKey(deviceId)) return;
    final peer = await _peer(deviceId, userId);
    if (app.deviceId.compareTo(deviceId) < 0) {
      final offer = await peer.pc.createOffer({});
      await peer.pc.setLocalDescription(offer);
      await _signal({'k': 'signal', 'to': deviceId, 'data': {'sdp': {'type': offer.type, 'sdp': offer.sdp}}}, toUser: userId);
    }
  }

  Future<void> _onRtc(String fromDevice, String fromUser, Map<String, dynamic> data) async {
    final peer = await _peer(fromDevice, fromUser);
    final sdp = data['sdp'];
    if (sdp is Map) {
      await peer.pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?));
      peer.remoteSet = true;
      for (final c in peer.pendingCandidates) {
        await peer.pc.addCandidate(c);
      }
      peer.pendingCandidates.clear();
      if (sdp['type'] == 'offer') {
        final answer = await peer.pc.createAnswer({});
        await peer.pc.setLocalDescription(answer);
        await _signal({'k': 'signal', 'to': fromDevice, 'data': {'sdp': {'type': answer.type, 'sdp': answer.sdp}}}, toUser: fromUser);
      }
    }
    final cand = data['candidate'];
    if (cand is Map) {
      final c = RTCIceCandidate(cand['candidate'] as String?, cand['sdpMid'] as String?, (cand['sdpMLineIndex'] as num?)?.toInt());
      if (peer.remoteSet) {
        await peer.pc.addCandidate(c);
      } else {
        peer.pendingCandidates.add(c);
      }
    }
  }

  Future<void> _removePeer(String deviceId) async {
    final p = peers.remove(deviceId);
    if (p == null) return;
    await p.pc.close();
    p.renderer.srcObject = null;
    await p.renderer.dispose();
    notifyListeners();
  }

  Future<void> _cleanup() async {
    _ticker?.cancel();
    _ticker = null;
    _ringTimer?.cancel();
    _heartbeat?.cancel();
    for (final id in peers.keys.toList()) {
      await _removePeer(id);
    }
    for (final t in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await localStream?.dispose();
    localStream = null;
    if (_rendererReady) localRenderer.srcObject = null;
    final call = active;
    active = null;
    connectedAt = null;
    if (call != null) ongoing.remove(call.chatId);
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await Helper.setSpeakerphoneOn(false);
      } catch (_) {}
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ incoming signaling
  Future<void> onSignal(String fromUser, String fromDevice, String chatId, Map<String, dynamic> p) async {
    try {
      await _handle(fromUser, fromDevice, chatId, p);
    } catch (e) {
      debugPrint('call signal error: $e');
    }
  }

  Future<void> _handle(String fromUser, String fromDevice, String chatId, Map<String, dynamic> p) async {
    if (fromDevice == app.deviceId) return;
    final callId = p['call'] as String? ?? '';
    final mine = fromUser == app.me?.id; // my other device
    final call = CallInfo(
      id: callId,
      chatId: chatId,
      video: p['video'] == true,
      startedBy: p['by'] as String? ?? fromUser,
      participants: [CallPeer(fromDevice, fromUser)],
    );
    final inThis = active?.id == callId;

    switch (p['k']) {
      case 'invite':
        _seen(call);
        if (mine) return;
        if (inCall) {
          // Busy.
          app.sendCallSignal(chatId, {'k': 'decline', 'call': callId, 'video': call.video, 'busy': true}, toUser: fromUser);
          return;
        }
        incoming = call;
        _incomingTimer?.cancel();
        _incomingTimer = Timer(const Duration(seconds: 45), () {
          if (incoming?.id == callId) {
            incoming = null;
            Notifications.cancelCall();
            notifyListeners();
          }
        });
        final chat = app.chats[chatId];
        final from = app.nameOf(fromUser);
        Notifications.call(
          callId: callId,
          chatId: chatId,
          title: chat != null && chat.isGroup ? app.chatTitle(chat) : from,
          body: 'Incoming ${call.video ? 'video' : 'voice'} call${chat != null && chat.isGroup ? ' from $from' : ''}',
        );
        notifyListeners();
      case 'join':
      case 'here':
        _seen(call);
        if (mine && incoming?.id == callId) {
          // Answered on my other device.
          incoming = null;
          Notifications.cancelCall();
        }
        if (inThis) {
          if (p['k'] == 'join') await _signal({'k': 'here'});
          await _meet(fromDevice, fromUser);
        }
        notifyListeners();
      case 'decline':
        if (mine && incoming?.id == callId) {
          incoming = null;
          Notifications.cancelCall();
          notifyListeners();
          return;
        }
        if (inThis && _iStarted && peers.isEmpty) {
          final chat = app.chats[chatId];
          // In a 1:1 call one "no" ends it; in groups we keep ringing the others.
          if (chat == null || !chat.isGroup || p['busy'] == true) await _finish(status: 'declined');
        }
      case 'leave':
        if (incoming?.id == callId && fromUser == incoming?.startedBy) {
          incoming = null;
          _incomingTimer?.cancel();
          Notifications.cancelCall();
        }
        if (inThis) {
          await _removePeer(fromDevice);
          if (peers.isEmpty && _answered) await _finish(status: 'completed');
        }
        final o = ongoing[chatId];
        if (o != null && o.id == callId) {
          o.participants.removeWhere((x) => x.peerId == fromDevice);
          if (o.participants.isEmpty) ongoing.remove(chatId);
        }
        notifyListeners();
      case 'signal':
        if (inThis && p['to'] == app.deviceId) await _onRtc(fromDevice, fromUser, (p['data'] as Map).cast<String, dynamic>());
      case 'media':
        final peer = peers[fromDevice];
        if (peer != null) {
          peer.audioOn = p['audio'] == true;
          peer.videoOn = p['vid'] == true;
          notifyListeners();
        }
    }
  }

  /// Remember a call in progress so the chat can offer "Join".
  void _seen(CallInfo call) {
    final o = ongoing[call.chatId];
    if (o == null || o.id != call.id) {
      ongoing[call.chatId] = CallInfo(
          id: call.id, chatId: call.chatId, video: call.video, startedBy: call.startedBy, participants: [...call.participants]);
    } else {
      for (final x in call.participants) {
        if (!o.participants.any((y) => y.peerId == x.peerId)) o.participants.add(x);
      }
    }
    _ongoingSeen[call.chatId] = DateTime.now();
    _ongoingSweep ??= Timer.periodic(const Duration(seconds: 10), (_) {
      final before = ongoing.length;
      ongoing.removeWhere((chatId, _) => DateTime.now().difference(_ongoingSeen[chatId] ?? DateTime(2000)).inSeconds > 40);
      if (ongoing.length != before) {
        notifyListeners();
        app.refresh();
      }
    });
    app.refresh();
  }
}
