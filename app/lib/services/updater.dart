// Auto-update from GitHub releases.
//
// A release needs these assets (the release workflow builds them):
//   HomeChat-windows-x64.zip   the Windows app folder, zipped
//   HomeChat-android.apk       the Android app (always signed with the same key)
//
// Windows: download, unzip, then a tiny script waits for the app to close,
//          copies the new files over it, and starts it again.
// Android: download the APK and open the system installer (Android always asks
//          the person to tap "Install").
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../version.dart';

class UpdateInfo {
  UpdateInfo({required this.version, required this.notes, required this.assetUrl, required this.size, required this.pageUrl});
  final String version;
  final String notes;
  final String? assetUrl; // null: no build for this platform in that release
  final int size;
  final String pageUrl;
}

/// 1.10.0 > 1.9.3. Ignores anything after "-" or "+".
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      v.replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[-+]')).first.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

class Updater {
  static bool get configured => !updateRepo.startsWith('YOUR_');

  static String? get _assetName => Platform.isWindows
      ? 'HomeChat-windows-x64.zip'
      : Platform.isAndroid
          ? 'HomeChat-android.apk'
          : null;

  /// The newest release if it's newer than this app; null if up to date.
  static Future<UpdateInfo?> check() async {
    if (!configured) return null;
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'),
      headers: {'accept': 'application/vnd.github+json', 'user-agent': 'HomeChat/$appVersion'},
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null; // no releases yet
    if (r.statusCode != 200) throw Exception('GitHub said ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final tag = j['tag_name'] as String? ?? '';
    if (compareVersions(tag, appVersion) <= 0) return null;
    Map<String, dynamic>? asset;
    for (final a in (j['assets'] as List? ?? const [])) {
      if ((a as Map)['name'] == _assetName) asset = a.cast<String, dynamic>();
    }
    return UpdateInfo(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      notes: j['body'] as String? ?? '',
      assetUrl: asset?['browser_download_url'] as String?,
      size: (asset?['size'] as num?)?.toInt() ?? 0,
      pageUrl: j['html_url'] as String? ?? 'https://github.com/$updateRepo/releases',
    );
  }

  /// Download and install. On Windows the app closes and restarts itself.
  static Future<void> install(UpdateInfo u, {void Function(double)? onProgress}) async {
    if (u.assetUrl == null) {
      await launchUrl(Uri.parse(u.pageUrl), mode: LaunchMode.externalApplication);
      return;
    }
    final tmp = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}homechat-update');
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    final file = File('${tmp.path}${Platform.pathSeparator}${_assetName!}');

    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(u.assetUrl!)));
      if (res.statusCode != 200) throw Exception('Download failed (${res.statusCode})');
      final total = res.contentLength ?? u.size;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
      await sink.close();
    } finally {
      client.close();
    }

    if (Platform.isAndroid) {
      final r = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      if (r.type != ResultType.done) throw Exception(r.message);
      return;
    }
    if (Platform.isWindows) return _applyWindows(file, tmp);
    await launchUrl(Uri.parse(u.pageUrl), mode: LaunchMode.externalApplication);
  }

  static Future<void> _applyWindows(File zip, Directory tmp) async {
    final exe = File(Platform.resolvedExecutable);
    final installDir = exe.parent.path;
    // Can we write next to the app? (Not if it was copied into Program Files.)
    try {
      final probe = File('$installDir${Platform.pathSeparator}.update-check');
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      throw Exception('Home Chat is in a protected folder ($installDir). Move the app folder to Documents or Desktop, '
          'or download the update from GitHub and replace the files yourself.');
    }
    final unpacked = Directory('${tmp.path}${Platform.pathSeparator}new');
    await unpacked.create();
    final tar = await Process.run('tar', ['-xf', zip.path, '-C', unpacked.path]);
    if (tar.exitCode != 0) throw Exception('Could not unpack the update: ${tar.stderr}');
    // The zip may contain the files directly, or one folder with them.
    var src = unpacked.path;
    final entries = unpacked.listSync();
    if (entries.length == 1 && entries.first is Directory) src = entries.first.path;

    final script = File('${tmp.path}${Platform.pathSeparator}apply-update.ps1');
    await script.writeAsString(r'''
param([int]$ProcId, [string]$Src, [string]$Dst, [string]$Exe)
try { Wait-Process -Id $ProcId -Timeout 30 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 700
robocopy $Src $Dst /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
Start-Process -FilePath (Join-Path $Dst $Exe)
''');
    await Process.start(
      'powershell',
      [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path,
        '-ProcId', '$pid', '-Src', src, '-Dst', installDir, '-Exe', exe.uri.pathSegments.last,
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
