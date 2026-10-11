import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../services/media.dart';
import 'widgets.dart';

/// Loads (downloads + decrypts) an attachment once per widget.
mixin _FileLoader<T extends StatefulWidget> on State<T> {
  FileRef get fileRef;
  Future<Uint8List>? bytes;

  Future<Uint8List> load() => bytes ??= AppScope.read(context).fileBytes(fileRef);
}

class EncryptedImage extends StatefulWidget {
  const EncryptedImage({super.key, required this.file, this.maxWidth = 280, this.maxHeight = 340, this.fit = BoxFit.cover, this.onTap});
  final FileRef file;
  final double maxWidth, maxHeight;
  final BoxFit fit;
  final VoidCallback? onTap;
  @override
  State<EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<EncryptedImage> with _FileLoader {
  @override
  FileRef get fileRef => widget.file;

  @override
  Widget build(BuildContext context) {
    final cached = AppScope.read(context).media.get(widget.file.id);
    final aspect = widget.file.aspect ?? 4 / 3;
    var w = widget.maxWidth;
    var h = w / aspect;
    if (h > widget.maxHeight) {
      h = widget.maxHeight;
      w = h * aspect;
    }
    Widget img(Uint8List b) => Image.memory(b, fit: widget.fit, gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined)));
    return GestureDetector(
      onTap: widget.onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth, maxHeight: widget.maxHeight, minWidth: 120, minHeight: 90),
        child: cached != null
            ? img(cached)
            : FutureBuilder<Uint8List>(
                future: load(),
                builder: (_, s) => s.hasData
                    ? img(s.data!)
                    : SizedBox(
                        width: w,
                        height: h,
                        child: Center(child: s.hasError ? const Icon(Icons.error_outline) : const CircularProgressIndicator(strokeWidth: 2)),
                      ),
              ),
      ),
    );
  }
}

/// Full-screen photo viewer with save.
class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.file, this.caption});
  final FileRef file;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.download),
            onPressed: () async {
              final f = await saveToDownloads(file.name, await app.fileBytes(file));
              if (context.mounted) toast(context, 'Saved to ${f.path}');
            },
          ),
          IconButton(
            tooltip: 'Open with…',
            icon: const Icon(Icons.open_in_new),
            onPressed: () async => openExternally(await writeTemp(file.id, file.name, await app.fileBytes(file))),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(child: EncryptedImage(file: file, maxWidth: 4000, maxHeight: 4000, fit: BoxFit.contain)),
          ),
        ),
        if (caption != null && caption!.isNotEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(caption!, style: const TextStyle(color: Colors.white))),
      ]),
    );
  }
}

/// Video tile: decrypt to a private temp file and hand it to the system player.
class VideoTile extends StatefulWidget {
  const VideoTile({super.key, required this.file});
  final FileRef file;
  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> with _FileLoader {
  @override
  FileRef get fileRef => widget.file;
  bool _busy = false;

  Future<void> _play() async {
    setState(() => _busy = true);
    try {
      final f = await writeTemp(widget.file.id, widget.file.name, await load());
      await openExternally(f);
    } catch (_) {
      if (mounted) toast(context, 'Could not open the video.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _busy ? null : _play,
      child: Container(
        width: 240,
        height: 150,
        color: Colors.black87,
        child: Stack(alignment: Alignment.center, children: [
          _busy
              ? const CircularProgressIndicator(color: Colors.white)
              : const Icon(Icons.play_circle_fill, size: 56, color: Colors.white),
          Positioned(
            left: 8,
            bottom: 6,
            child: Text('🎬 ${humanSize(widget.file.size)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}

/// Voice message player.
class VoicePlayer extends StatefulWidget {
  const VoicePlayer({super.key, required this.file, required this.color});
  final FileRef file;
  final Color color;
  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> with _FileLoader {
  @override
  FileRef get fileRef => widget.file;
  AudioPlayer? _player;
  final List<StreamSubscription> _subs = [];
  Duration _pos = Duration.zero;
  Duration? _dur;
  bool _playing = false;
  bool _loading = false;

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player?.pause();
      return;
    }
    if (_player == null) {
      setState(() => _loading = true);
      try {
        final f = await writeTemp(widget.file.id, widget.file.name, await load());
        final p = AudioPlayer();
        _player = p;
        _subs.add(p.onPositionChanged.listen((d) => setState(() => _pos = d)));
        _subs.add(p.onDurationChanged.listen((d) => setState(() => _dur = d)));
        _subs.add(p.onPlayerStateChanged.listen((s) => setState(() => _playing = s == PlayerState.playing)));
        _subs.add(p.onPlayerComplete.listen((_) => setState(() {
              _playing = false;
              _pos = Duration.zero;
            })));
        await p.play(DeviceFileSource(f.path));
      } catch (_) {
        if (mounted) toast(context, 'Could not play this voice message.');
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }
    await _player!.resume();
  }

  @override
  Widget build(BuildContext context) {
    final total = _dur ?? Duration(milliseconds: widget.file.durationMs ?? 0);
    final progress = total.inMilliseconds == 0 ? 0.0 : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: 220,
      child: Row(children: [
        IconButton(
          onPressed: _loading ? null : _toggle,
          icon: _loading
              ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: widget.color))
              : Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 36, color: widget.color),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
              child: Slider(
                value: progress,
                activeColor: widget.color,
                onChanged: _player == null || total.inMilliseconds == 0
                    ? null
                    : (v) => _player!.seek(Duration(milliseconds: (v * total.inMilliseconds).round())),
              ),
            ),
            const SizedBox(height: 4),
            Text(duration(_playing || _pos > Duration.zero ? _pos : total), style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

/// Document / generic file.
class FileTile extends StatefulWidget {
  const FileTile({super.key, required this.file, required this.color});
  final FileRef file;
  final Color color;
  @override
  State<FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<FileTile> with _FileLoader {
  @override
  FileRef get fileRef => widget.file;
  bool _busy = false;

  Future<void> _open({bool save = false}) async {
    setState(() => _busy = true);
    try {
      final b = await load();
      if (save) {
        final f = await saveToDownloads(widget.file.name, b);
        if (mounted) toast(context, 'Saved to ${f.path}');
      } else {
        await openExternally(await writeTemp(widget.file.id, widget.file.name, b));
      }
    } catch (_) {
      if (mounted) toast(context, 'Could not open the file.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData get _icon {
    final m = widget.file.mime;
    if (m.startsWith('audio/')) return Icons.audiotrack;
    if (m == 'application/pdf') return Icons.picture_as_pdf;
    if (m.contains('zip')) return Icons.folder_zip;
    if (m.contains('sheet') || m.contains('excel')) return Icons.table_chart;
    if (m.contains('word') || m.startsWith('text/')) return Icons.description;
    if (m.startsWith('image/')) return Icons.image;
    return Icons.insert_drive_file;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _busy ? null : _open,
      child: SizedBox(
        width: 240,
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
            child: _busy
                ? Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: widget.color))
                : Icon(_icon, color: widget.color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.file.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              Text(humanSize(widget.file.size), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
          IconButton(tooltip: 'Save', icon: const Icon(Icons.download, size: 20), onPressed: _busy ? null : () => _open(save: true)),
        ]),
      ),
    );
  }
}

/// A custom sticker kept on this device (image file).
class LocalStickerImage extends StatelessWidget {
  const LocalStickerImage({super.key, required this.path, this.size = 72});
  final String path;
  final double size;
  @override
  Widget build(BuildContext context) => Image.file(File(path), width: size, height: size, fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, size: size / 2));
}
