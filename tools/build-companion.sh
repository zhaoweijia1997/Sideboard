#!/bin/zsh
# Builds the Android companion app (android/) and copies it to Resources/SideboardCompanion.apk,
# where build.sh bundles it into Sideboard.app. Needs Android Studio (for its Java) and the
# Android SDK (android/local.properties or ANDROID_HOME). Signed with the release key when
# ../Sideboard-签名 exists, otherwise with your debug key.
set -euo pipefail
cd "$(dirname "$0")/../android"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
./gradlew assembleRelease -q
cp app/build/outputs/apk/release/app-release.apk ../Resources/SideboardCompanion.apk
# Its version, so Sideboard can offer an update to devices with an older one.
sed -nE 's/^ *versionName = "(.*)"/\1/p' app/build.gradle.kts > ../Resources/SideboardCompanion.version
echo "Wrote Resources/SideboardCompanion.apk ($(cat ../Resources/SideboardCompanion.version))"
