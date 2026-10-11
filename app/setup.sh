#!/usr/bin/env bash
# Home Chat app — one-time setup + builds (macOS / Linux).
# Needs Flutter installed: https://docs.flutter.dev/get-started/install
#   ./setup.sh          set up + build the desktop app for this OS and the Android APK
#   ./setup.sh run      set up + run on this computer
set -euo pipefail
cd "$(dirname "$0")"

case "$(uname -s)" in
  Darwin) DESKTOP=macos ;;
  *) DESKTOP=linux ;;
esac

echo "==> Generating platform folders (keeps our files)"
flutter create --org net.homechat --project-name homechat --platforms "android,$DESKTOP" .
dart run tool/patch_platforms.dart
flutter pub get
flutter test

if [[ "${1:-}" == "run" ]]; then
  exec flutter run -d "$DESKTOP"
fi

echo "==> Building $DESKTOP app"
flutter build "$DESKTOP" --release
echo "==> Building Android APK"
flutter build apk --release

echo
echo "Done!"
if [[ "$DESKTOP" == "macos" ]]; then
  echo "  Mac app     : build/macos/Build/Products/Release/homechat.app"
else
  echo "  Linux app   : build/linux/x64/release/bundle/homechat"
  echo "  (Linux needs: sudo apt install libgtk-3-dev libsecret-1-dev libpulse-dev — and for voice notes, see README)"
fi
echo "  Android APK : build/app/outputs/flutter-apk/app-release.apk"
