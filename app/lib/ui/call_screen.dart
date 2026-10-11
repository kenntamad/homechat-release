import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/calls.dart';
import 'widgets.dart';

const _green = Color(0xFF34C759);
const _red = Color(0xFFFF3B30);

/// Sits above every screen: incoming-call card and the in-call view.
class CallOverlay extends StatefulWidget {
  const CallOverlay({super.key});
  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  bool _minimized = false;
  String? _lastError;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final calls = app.calls;
    return ListenableBuilder(
      listenable: calls,
      builder: (context, _) {
        if (calls.error != null && calls.error != _lastError) {
          _lastError = calls.error;
          final msg = calls.error!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            calls.error = null;
            _lastError = null;
            final m = ScaffoldMessenger.maybeOf(context);
            m?.showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
          });
        }
        if (!calls.inCall) _minimized = false;
        final children = <Widget>[];
        if (calls.inCall) {
          children.add(_minimized
              ? Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: _green,
                      child: InkWell(
                        onTap: () => setState(() => _minimized = false),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'Tap to return to call${calls.connectedAt != null ? ' · ${duration(DateTime.now().difference(calls.connectedAt!))}' : ''}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : Positioned.fill(child: CallView(onMinimize: () => setState(() => _minimized = true))));
        }
        if (calls.incoming != null) children.add(const IncomingCallCard());
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(children: children);
      },
    );
  }
}

class IncomingCallCard extends StatelessWidget {
  const IncomingCallCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final call = app.calls.incoming!;
    final chat = app.chats[call.chatId];
    final caller = app.users[call.startedBy];
    final title = chat != null && chat.isGroup ? app.chatTitle(chat) : (caller?.displayName ?? 'Someone');
    final sub = '${call.video ? 'Video' : 'Voice'} call${chat != null && chat.isGroup ? ' · ${caller?.displayName ?? ''}' : ''}';
    final wide = MediaQuery.sizeOf(context).width >= 840;

    final card = Material(
      elevation: 12,
      color: const Color(0xFF2B2440),
      borderRadius: BorderRadius.circular(wide ? 18 : 0),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              chat != null && chat.isGroup ? ChatAvatar(chat: chat, size: 56) : Avatar.user(caller, size: 56, showOnline: false),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                  Text(sub, style: const TextStyle(color: Colors.white70)),
                ]),
              ),
            ]),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _RoundButton(icon: Icons.call_end, color: _red, label: 'Decline', onTap: app.calls.decline),
              _RoundButton(icon: call.video ? Icons.videocam : Icons.call, color: _green, label: 'Answer', onTap: app.calls.accept),
            ]),
          ]),
        ),
      ),
    );
    return Positioned(
      top: wide ? 20 : 0,
      right: wide ? 20 : 0,
      left: wide ? null : 0,
      width: wide ? 380 : null,
      child: card,
    );
  }
}

class CallView extends StatelessWidget {
  const CallView({super.key, required this.onMinimize});
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final calls = app.calls;
    final call = calls.active!;
    final chat = app.chats[call.chatId];
    final title = chat == null ? 'Call' : app.chatTitle(chat);
    final peers = calls.peers.values.toList();
    final mobile = Platform.isAndroid || Platform.isIOS;

    String status;
    if (peers.isEmpty) {
      status = call.id.isEmpty ? 'Starting…' : 'Ringing…';
    } else if (calls.connectedAt == null) {
      status = 'Connecting…';
    } else {
      status = duration(DateTime.now().difference(calls.connectedAt!));
    }

    Widget tile(CallPeerConn p) {
      final u = app.users[p.userId];
      final showVideo = p.hasVideo && p.videoOn;
      return Container(
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: const Color(0xFF1E1A2E), borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [
          if (showVideo)
            RTCVideoView(p.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else ...[
            // Audio still plays through the (hidden) renderer.
            Offstage(child: SizedBox(width: 1, height: 1, child: RTCVideoView(p.renderer))),
            Center(child: Avatar.user(u, size: 96, showOnline: false)),
          ],
          Positioned(
            left: 10,
            bottom: 8,
            child: Row(children: [
              if (!p.audioOn) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.mic_off, color: Colors.white, size: 16)),
              Text(u?.displayName ?? '', style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
              if (p.state != 'connected')
                Text(' · ${p.state}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
        ]),
      );
    }

    Widget stage;
    if (peers.isEmpty) {
      stage = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          chat != null ? ChatAvatar(chat: chat, size: 120) : const SizedBox(),
          const SizedBox(height: 20),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(status, style: const TextStyle(color: Colors.white70, fontSize: 16)),
        ]),
      );
    } else if (peers.length == 1) {
      stage = tile(peers.first);
    } else {
      final cols = peers.length <= 4 ? 2 : 3;
      stage = GridView.count(crossAxisCount: cols, childAspectRatio: 3 / 4, padding: const EdgeInsets.all(4), children: [for (final p in peers) tile(p)]);
    }

    final showLocal = call.video && calls.cameraOn && calls.localStream != null;

    return Material(
      color: const Color(0xFF15121F),
      child: SafeArea(
        child: Stack(children: [
          Positioned.fill(child: stage),
          // header
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent]),
              ),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white), onPressed: onMinimize),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                    Text(peers.isEmpty ? '🔒 End-to-end encrypted' : status, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ]),
                ),
              ]),
            ),
          ),
          // self view
          if (showLocal)
            Positioned(
              right: 12,
              top: 70,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(calls.localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              ),
            ),
          // controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 10, children: [
              _RoundButton(
                icon: calls.micOn ? Icons.mic : Icons.mic_off,
                color: calls.micOn ? Colors.white24 : Colors.white,
                iconColor: calls.micOn ? Colors.white : Colors.black,
                onTap: calls.toggleMic,
                tooltip: calls.micOn ? 'Mute' : 'Unmute',
              ),
              if (call.video)
                _RoundButton(
                  icon: calls.cameraOn ? Icons.videocam : Icons.videocam_off,
                  color: calls.cameraOn ? Colors.white24 : Colors.white,
                  iconColor: calls.cameraOn ? Colors.white : Colors.black,
                  onTap: calls.toggleCamera,
                  tooltip: 'Camera',
                ),
              if (call.video && mobile)
                _RoundButton(icon: Icons.cameraswitch, color: Colors.white24, onTap: calls.switchCamera, tooltip: 'Switch camera'),
              if (mobile)
                _RoundButton(
                  icon: calls.speakerOn ? Icons.volume_up : Icons.hearing,
                  color: calls.speakerOn ? Colors.white : Colors.white24,
                  iconColor: calls.speakerOn ? Colors.black : Colors.white,
                  onTap: calls.toggleSpeaker,
                  tooltip: 'Speaker',
                ),
              _RoundButton(icon: Icons.call_end, color: _red, onTap: calls.hangUp, tooltip: 'Hang up'),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.color, required this.onTap, this.label, this.tooltip, this.iconColor = Colors.white});
  final IconData icon;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;
  final String? label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // No Tooltip here: this view lives above the Navigator, outside any Overlay.
    final btn = Semantics(
      label: tooltip ?? label ?? '',
      button: true,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(16), child: Icon(icon, color: iconColor, size: 28)),
        ),
      ),
    );
    if (label == null) return btn;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      btn,
      const SizedBox(height: 6),
      Text(label!, style: const TextStyle(color: Colors.white70)),
    ]);
  }
}
