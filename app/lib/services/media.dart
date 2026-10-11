import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

String mimeFor(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const map = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp',
    'heic': 'image/heic', 'bmp': 'image/bmp',
    'mp4': 'video/mp4', 'mov': 'video/quicktime', 'mkv': 'video/x-matroska', 'webm': 'video/webm', '3gp': 'video/3gpp',
    'm4a': 'audio/mp4', 'aac': 'audio/aac', 'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'wav': 'audio/wav', 'opus': 'audio/opus',
    'pdf': 'application/pdf', 'txt': 'text/plain', 'zip': 'application/zip',
    'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };
  return map[ext] ?? 'application/octet-stream';
}

/// Images the Flutter Image widget can decode (HEIC is opened externally).
bool isDisplayableImage(String mime) => const {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp'}.contains(mime);

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

String safeFileName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');

/// Small in-memory LRU for decrypted attachments so scrolling doesn't re-download.
class MediaCache {
  MediaCache({this.maxBytes = 120 * 1024 * 1024});
  final int maxBytes;
  final _map = <String, Uint8List>{};
  int _size = 0;

  Uint8List? get(String id) {
    final v = _map.remove(id);
    if (v != null) _map[id] = v;
    return v;
  }

  void put(String id, Uint8List bytes) {
    if (bytes.length > maxBytes ~/ 3) return;
    final old = _map.remove(id);
    if (old != null) _size -= old.length;
    _map[id] = bytes;
    _size += bytes.length;
    while (_size > maxBytes && _map.isNotEmpty) {
      final k = _map.keys.first;
      _size -= _map.remove(k)!.length;
    }
  }
}

/// Write decrypted bytes to a private temp file (for players / "open with").
Future<File> writeTemp(String id, String name, Uint8List bytes) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/homechat');
  await dir.create(recursive: true);
  final f = File('${dir.path}/${id}_${safeFileName(name)}');
  if (!await f.exists() || await f.length() != bytes.length) await f.writeAsBytes(bytes, flush: true);
  return f;
}

Future<void> openExternally(File f) async {
  await OpenFilex.open(f.path);
}

/// Save a copy where the user can find it (Downloads on desktop, app documents on phones).
Future<File> saveToDownloads(String name, Uint8List bytes) async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } catch (_) {}
  if (Platform.isAndroid) {
    final ext = Directory('/storage/emulated/0/Download');
    if (await ext.exists()) dir = ext;
  }
  dir ??= await getApplicationDocumentsDirectory();
  try {
    return await _writeUnique(dir, name, bytes);
  } catch (_) {
    // Some Android versions refuse direct writes to Download; keep it in app storage.
    return _writeUnique(await getApplicationDocumentsDirectory(), name, bytes);
  }
}

Future<File> _writeUnique(Directory dir, String name, Uint8List bytes) async {
  var f = File('${dir.path}/${safeFileName(name)}');
  var i = 1;
  while (await f.exists()) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    f = File('${dir.path}/${safeFileName('$base ($i)$ext')}');
    i++;
  }
  return f.writeAsBytes(bytes, flush: true);
}

/// Shrink a picture to a small square-ish PNG (for profile photos, which travel inside profiles).
Future<Uint8List> shrinkImage(Uint8List bytes, {int maxSide = 112}) async {
  final probe = await ui.instantiateImageCodec(bytes);
  final first = (await probe.getNextFrame()).image;
  final w = first.width, h = first.height;
  first.dispose();
  final scale = maxSide / (w > h ? w : h);
  final codec = await ui.instantiateImageCodec(bytes,
      targetWidth: scale < 1 ? (w * scale).round() : w, targetHeight: scale < 1 ? (h * scale).round() : h);
  final img = (await codec.getNextFrame()).image;
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}
