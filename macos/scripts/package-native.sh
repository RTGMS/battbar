#!/bin/bash
# Package the native app as a universal .zip and .dmg, then refresh checksums.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="$(cd "$ROOT/.." && pwd)/release"
APP="$ROOT/build/BattBar.app"

# Prefer the version embedded in the built app, then the environment.
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)}"
VERSION="${VERSION:-2.1.0}"
VERSION="${VERSION#v}"
NAME="BattBar-$VERSION-mac-universal"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build-native.sh"
fi

mkdir -p "$RELEASE"
rm -f "$RELEASE/$NAME.zip" "$RELEASE/$NAME.dmg"
rm -rf "$ROOT/build/dmg-stage"
mkdir -p "$ROOT/build/dmg-stage"
cp -R "$APP" "$ROOT/build/dmg-stage/"
ln -s /Applications "$ROOT/build/dmg-stage/Applications"

echo "创建 ZIP …"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE/$NAME.zip"

echo "创建 DMG …"
hdiutil create \
  -volname "BattBar" \
  -srcfolder "$ROOT/build/dmg-stage" \
  -ov -format UDZO \
  "$RELEASE/$NAME.dmg" >/dev/null

rm -rf "$ROOT/build/dmg-stage"

echo "更新 SHA256SUMS.txt …"
(
  cd "$RELEASE"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS.txt' -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 \
    | sed 's|  \./|  |' \
    > SHA256SUMS.txt
)

ls -lh "$RELEASE/$NAME.zip" "$RELEASE/$NAME.dmg" "$RELEASE/SHA256SUMS.txt"
