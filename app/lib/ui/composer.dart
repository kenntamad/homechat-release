import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../services/media.dart';
import '../state/app_state.dart';
import 'stickers.dart';
import 'widgets.dart';

/// Bottom bar of a chat: text, emoji/stickers, attachments and voice notes.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.chat, required this.replyTo, required this.editing, required this.onClearContext});
  final Chat chat;
  final Message? replyTo;
  final Message? editing;
  final VoidCallback onClearContext;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _panel = false;
  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<double> _progress = ValueNotifier(0);
  int _uploads = 0;

  // voice recording
  final AudioRecorder _rec = AudioRecorder();
  bool _recording = false;
  DateTime? _recStart;
  Timer? _recTimer;
  String? _recPath;

  bool get _isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  // Kept so we can still say "stopped typing" while the widget is being disposed.
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.read(context);
  }

  @override
  void didUpdateWidget(covariant Composer old) {
    super.didUpdateWidget(old);
    if (widget.editing != null && widget.editing != old.editing) {
      _text.text = widget.editing!.payload?.text ?? '';
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
      _focus.requestFocus();
    }
    if (widget.replyTo != null && widget.replyTo != old.replyTo) _focus.requestFocus();
  }

  @override
  void dispose() {
    _stopTyping();
    _recTimer?.cancel();
    _rec.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void insertText(String s) {
    final sel = _text.selection;
    final start = sel.isValid ? sel.start : _text.text.length;
    final end = sel.isValid ? sel.end : _text.text.length;
    _text.text = _text.text.replaceRange(start, end, s);
    _text.selection = TextSelection.collapsed(offset: start + s.length);
    setState(() {});
  }

  void _onChanged(String v) {
    setState(() {});
    final app = AppScope.read(context);
    if (v.isEmpty) return _stopTyping();
    if (DateTime.now().difference(_lastTyping).inSeconds >= 3) {
      _lastTyping = DateTime.now();
      app.setTyping(widget.chat.id, true);
    }
  }

  void _stopTyping() {
    if (_lastTyping.millisecondsSinceEpoch == 0) return;
    _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
    _app?.setTyping(widget.chat.id, false);
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final app = AppScope.read(context);
    final editing = widget.editing;
    final reply = widget.replyTo;
    _text.clear();
    _stopTyping();
    widget.onClearContext();
    setState(() {});
    try {
      if (editing != null) {
        await app.edit(editing, text);
      } else {
        await app.sendText(widget.chat.id, text, replyTo: reply);
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  // ------------------------------------------------------------------ attachments
  Future<void> sendBytes(Uint8List bytes, String name, {String? kind, int? durationMs}) async {
    final app = AppScope.read(context);
    final mime = mimeFor(name);
    final k = kind ??
        (mime == 'image/gif'
            ? 'gif'
            : isDisplayableImage(mime)
                ? 'image'
                : mime.startsWith('video/')
                    ? 'video'
                    : 'file');
    final reply = widget.replyTo;
    final caption = k == 'image' || k == 'video' ? _text.text.trim() : '';
    if (caption.isNotEmpty) _text.clear();
    widget.onClearContext();
    setState(() => _uploads++);
    try {
      final viaRelays = await app.sendFile(widget.chat.id, bytes: bytes, name: name, kind: k, caption: caption,
          durationMs: durationMs, replyTo: reply, progress: _progress);
      if (!viaRelays && mounted) {
        toast(context, 'Big file (over 8 MB): it reaches the others directly when you\'re on the same Wi‑Fi.');
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _uploads--);
    }
  }

  Future<void> _pickFiles({FileType type = FileType.any}) async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true, type: type, withData: false);
    if (res == null) return;
    for (final f in res.files) {
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null) bytes = await File(f.path!).readAsBytes();
      if (bytes == null) continue;
      await sendBytes(bytes, f.name);
    }
  }

  Future<void> _camera({bool video = false}) async {
    final picker = ImagePicker();
    final x = video
        ? await picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 5))
        : await picker.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2560);
    if (x == null) return;
    await sendBytes(await x.readAsBytes(), x.name);
  }

  void _attachMenu() {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Wrap(children: [
          if (Platform.isAndroid || Platform.isIOS) ...[
            ListTile(leading: const Icon(Icons.photo_camera, color: brand), title: const Text('Take photo'),
                onTap: () { Navigator.pop(c); _camera(); }),
            ListTile(leading: const Icon(Icons.videocam, color: brand), title: const Text('Record video'),
                onTap: () { Navigator.pop(c); _camera(video: true); }),
          ],
          ListTile(leading: const Icon(Icons.photo_library, color: brand), title: const Text('Photos & videos'),
              onTap: () { Navigator.pop(c); _pickFiles(type: FileType.media); }),
          ListTile(leading: const Icon(Icons.gif_box, color: brand), title: const Text('GIF'),
              onTap: () { Navigator.pop(c); _pickGif(); }),
          ListTile(leading: const Icon(Icons.insert_drive_file, color: brand), title: const Text('File'),
              onTap: () { Navigator.pop(c); _pickFiles(); }),
        ]),
      ),
    );
  }

  Future<void> _pickGif() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['gif'], withData: false);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes != null) await sendBytes(bytes, f.name, kind: 'gif');
  }

  // ------------------------------------------------------------------ voice notes
  Future<void> _startRecording() async {
    if (!await _rec.hasPermission()) {
      if (mounted) toast(context, 'Allow microphone access to record voice messages.');
      return;
    }
    var encoder = AudioEncoder.aacLc;
    var ext = 'm4a';
    if (!await _rec.isEncoderSupported(encoder)) {
      encoder = AudioEncoder.opus;
      ext = 'ogg';
      if (!await _rec.isEncoderSupported(encoder)) {
        encoder = AudioEncoder.wav;
        ext = 'wav';
      }
    }
    final dir = await getTemporaryDirectory();
    _recPath = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _rec.start(RecordConfig(encoder: encoder, numChannels: 1), path: _recPath!);
    _recStart = DateTime.now();
    _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
    setState(() => _recording = true);
    AppScope.read(context).setTyping(widget.chat.id, true);
  }

  Future<void> _stopRecording({required bool send}) async {
    _recTimer?.cancel();
    final path = await _rec.stop();
    final started = _recStart;
    setState(() => _recording = false);
    _stopTyping();
    final p = path ?? _recPath;
    if (!send || p == null || started == null) return;
    final ms = DateTime.now().difference(started).inMilliseconds;
    if (ms < 700) {
      if (mounted) toast(context, 'Too short — tap the mic, talk, then tap send.');
      return;
    }
    final f = File(p);
    final bytes = await f.readAsBytes();
    await sendBytes(bytes, f.uri.pathSegments.last, kind: 'voice', durationMs: ms);
    unawaited(f.delete().catchError((_) => f));
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ctxMsg = widget.editing ?? widget.replyTo;
    final hasText = _text.text.trim().isNotEmpty;

    return Material(
      color: scheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_uploads > 0)
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (_, v, __) => LinearProgressIndicator(value: v > 0 && v < 1 ? v : null, minHeight: 2),
            ),
          if (ctxMsg != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(children: [
                Icon(widget.editing != null ? Icons.edit : Icons.reply, color: brand, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.editing != null ? 'Edit message' : 'Reply to ${app.nameOf(ctxMsg.senderId)}',
                        style: const TextStyle(color: brand, fontWeight: FontWeight.w600, fontSize: 13)),
                    Text(ctxMsg.payload?.preview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  ]),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    if (widget.editing != null) _text.clear();
                    widget.onClearContext();
                  },
                ),
              ]),
            ),
          if (_recording)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(children: [
                IconButton(tooltip: 'Discard', icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => _stopRecording(send: false)),
                const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
                const SizedBox(width: 8),
                Text(duration(DateTime.now().difference(_recStart ?? DateTime.now())), style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 12),
                const Expanded(child: Text('Recording…', style: TextStyle(color: Colors.grey))),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: brand),
                  icon: const Icon(Icons.send, color: Colors.white),
                  onPressed: () => _stopRecording(send: true),
                ),
              ]),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                IconButton(tooltip: 'Attach', icon: const Icon(Icons.add_circle_outline, color: brand), onPressed: _attachMenu),
                IconButton(
                  tooltip: 'Stickers & emoji',
                  icon: Icon(_panel ? Icons.keyboard : Icons.emoji_emotions_outlined, color: brand),
                  onPressed: () {
                    setState(() => _panel = !_panel);
                    if (_panel) {
                      _focus.unfocus();
                    } else {
                      _focus.requestFocus();
                    }
                  },
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      // Desktop: Enter sends, Shift+Enter makes a new line.
                      if (_isDesktop && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        _send();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      onChanged: _onChanged,
                      onTap: () => setState(() => _panel = false),
                      decoration: InputDecoration(
                        hintText: widget.chat.disappearSeconds > 0 ? 'Disappearing message…' : 'Type a message…',
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (hasText || widget.editing != null)
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: brand),
                    tooltip: widget.editing != null ? 'Save' : 'Send',
                    icon: Icon(widget.editing != null ? Icons.check : Icons.send, color: Colors.white),
                    onPressed: _send,
                  )
                else
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: brand),
                    tooltip: 'Voice message',
                    icon: const Icon(Icons.mic, color: Colors.white),
                    onPressed: _startRecording,
                  ),
              ]),
            ),
          if (_panel && !_recording)
            StickerPanel(
              onEmoji: insertText,
              onSticker: (e) {
                final reply = widget.replyTo;
                widget.onClearContext();
                if (reply != null) {
                  app.sendPayload(widget.chat.id, {'t': 'sticker', 'emoji': e, 'reply': app.replyRef(reply)});
                } else {
                  app.sendSticker(widget.chat.id, e);
                }
              },
              onCustom: (path) async {
                final f = File(path);
                await sendBytes(await f.readAsBytes(), f.uri.pathSegments.last, kind: 'sticker');
              },
            ),
        ]),
      ),
    );
  }
}
