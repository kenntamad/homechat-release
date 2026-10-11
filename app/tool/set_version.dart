// Sets the app version everywhere it lives.
//   dart run tool/set_version.dart v2.1.0 [buildNumber]
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/set_version.dart <version> [buildNumber]');
    exit(64);
  }
  final version = args[0].replaceFirst(RegExp(r'^[vV]'), '');
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    stderr.writeln('Version must look like 2.1.0 (got "$version")');
    exit(64);
  }
  final parts = version.split('.').map(int.parse).toList();
  // Android needs an ever-increasing number; derive one from the version unless given.
  final build = args.length > 1 ? int.parse(args[1]) : parts[0] * 10000 + parts[1] * 100 + parts[2];

  final pubspec = File('pubspec.yaml');
  pubspec.writeAsStringSync(pubspec.readAsStringSync().replaceFirst(RegExp(r'^version: .*$', multiLine: true), 'version: $version+$build'));
  File('lib/version.dart').writeAsStringSync(
      "// Set by tool/set_version.dart (the release workflow runs it from the git tag).\nconst appVersion = '$version';\n");
  stdout.writeln('Version set to $version (build $build)');
}
