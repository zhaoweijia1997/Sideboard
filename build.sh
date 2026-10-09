#!/bin/zsh
# Build Sideboard.app into build.noindex/ (a .noindex folder, so Spotlight and
# Launchpad don't list the build copy as a second app).
#
#   ./build.sh            build a universal (Apple silicon + Intel) app
#   ./build.sh --install  also copy it to /Applications
#   ./build.sh --dmg      also make build.noindex/Sideboard-<version>.dmg for a GitHub release
set -euo pipefail
# The Xcode toolchain is required: the Command Line Tools lack SwiftUI's macro plugins.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/Sideboard"

APP=build.noindex/Sideboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sideboard"
# Debug symbols carry the build folder's full path (user name included); the app doesn't need them.
strip -S "$APP/Contents/MacOS/Sideboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The Android companion app, installed on devices from Sideboard (tools/build-companion.sh rebuilds it).
[[ -f Resources/SideboardCompanion.apk ]] && cp Resources/SideboardCompanion.apk Resources/SideboardCompanion.version "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
echo "Built $APP"

case "${1:-}" in
--install)
  if [[ -d /Applications/Sideboard.app ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Sideboard.app/Contents/Info.plist)" == "com.weijiazhao.sideboard" ]] \
      || { echo "/Applications/Sideboard.app is a different app; not replacing it"; exit 1; }
    rm -rf /Applications/Sideboard.app
  fi
  ditto "$APP" /Applications/Sideboard.app
  "$LSREGISTER" -f /Applications/Sideboard.app
  echo "Installed /Applications/Sideboard.app"
  ;;
--dmg)
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  STAGE=build.noindex/dmg
  DMG="build.noindex/Sideboard-$VERSION.dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Sideboard.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Sideboard $VERSION" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
  echo "Made $DMG"
  ;;
esac
