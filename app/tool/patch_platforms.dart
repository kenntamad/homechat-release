// Run after `flutter create` (setup scripts do this for you):
//   dart run tool/patch_platforms.dart
//
// Applies the few platform settings the plugins need. Safe to run repeatedly.
import 'dart:io';

void main() {
  _android();
  _windows();
  _macos();
  stdout.writeln('Platform files patched.');
}

void _android() {
  final kts = File('android/app/build.gradle.kts');
  final groovy = File('android/app/build.gradle');
  if (kts.existsSync()) {
    var s = kts.readAsStringSync();
    s = s.replaceAll(RegExp(r'minSdk\s*=\s*flutter\.minSdkVersion'), 'minSdk = 24');
    if (!s.contains('isCoreLibraryDesugaringEnabled')) {
      s = s.replaceFirst(RegExp(r'compileOptions\s*\{'), 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true');
    }
    if (!s.contains('desugar_jdk_libs')) {
      s += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n';
    }
    // Release signing from android/key.properties (made by setup.ps1, or by the release workflow).
    // Every release must be signed with the same key, or phones refuse to update.
    if (!s.contains('keystorePropertiesFile')) {
      s = s.replaceFirst(RegExp(r'\nandroid\s*\{'), '''

val keystoreProperties = java.util.Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(java.io.FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }''');
      s = s.replaceFirst('signingConfig = signingConfigs.getByName("debug")',
          'signingConfig = if (keystorePropertiesFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")');
    }
    kts.writeAsStringSync(s);
    stdout.writeln('  android/app/build.gradle.kts ✓');
  } else if (groovy.existsSync()) {
    var s = groovy.readAsStringSync();
    s = s
        .replaceAll(RegExp(r'minSdkVersion\s+flutter\.minSdkVersion'), 'minSdkVersion 24')
        .replaceAll(RegExp(r'minSdk\s*=\s*flutter\.minSdkVersion'), 'minSdk = 24');
    if (!s.contains('coreLibraryDesugaringEnabled')) {
      s = s.replaceFirst(RegExp(r'compileOptions\s*\{'), 'compileOptions {\n        coreLibraryDesugaringEnabled true');
    }
    if (!s.contains('desugar_jdk_libs')) {
      s += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n";
    }
    groovy.writeAsStringSync(s);
    stdout.writeln('  android/app/build.gradle ✓');
  }
}

void _windows() {
  final f = File('windows/CMakeLists.txt');
  if (!f.existsSync()) return;
  const line = 'add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)';
  var s = f.readAsStringSync();
  if (s.contains(line)) return;
  s = s.replaceFirst('include(flutter/generated_plugins.cmake)',
      '# Visual Studio 2026 (MSVC 14.5x) rejects <experimental/coroutine>, which some\n'
      '# plugins (flutter_local_notifications_windows) still use. Allow it for now.\n'
      '$line\ninclude(flutter/generated_plugins.cmake)');
  f.writeAsStringSync(s);
  stdout.writeln('  windows/CMakeLists.txt ✓');
}

void _macos() {
  const entitlements = {
    'com.apple.security.network.client': true,
    'com.apple.security.device.camera': true,
    'com.apple.security.device.audio-input': true,
  };
  for (final name in ['DebugProfile.entitlements', 'Release.entitlements']) {
    final f = File('macos/Runner/$name');
    if (!f.existsSync()) continue;
    var s = f.readAsStringSync();
    for (final e in entitlements.entries) {
      if (s.contains(e.key)) continue;
      s = s.replaceFirst(RegExp(r'</dict>\s*</plist>'), '\t<key>${e.key}</key>\n\t<true/>\n</dict>\n</plist>');
    }
    f.writeAsStringSync(s);
    stdout.writeln('  macos/Runner/$name ✓');
  }
  final plist = File('macos/Runner/Info.plist');
  if (plist.existsSync()) {
    var s = plist.readAsStringSync();
    const usage = {
      'NSCameraUsageDescription': 'Home Chat uses the camera for video calls.',
      'NSMicrophoneUsageDescription': 'Home Chat uses the microphone for calls and voice messages.',
    };
    for (final e in usage.entries) {
      if (s.contains(e.key)) continue;
      s = s.replaceFirst(RegExp(r'</dict>\s*</plist>'), '\t<key>${e.key}</key>\n\t<string>${e.value}</string>\n</dict>\n</plist>');
    }
    plist.writeAsStringSync(s);
    stdout.writeln('  macos/Runner/Info.plist ✓');
  }
}
