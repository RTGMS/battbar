#!/bin/bash
# Build the native macOS menu bar app. Requires Xcode Command Line Tools only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/BattBar/Sources"
BUILD="$ROOT/build"
APP="$BUILD/小鼠电量.app"
VERSION="${VERSION:-2.0.0}"
VERSION="${VERSION#v}"
BUNDLE_ID="com.mousebattery.app"

choose_sdk() {
  if [[ -n "${MOUSEBATTERY_SDK:-}" ]]; then
    printf '%s\n' "$MOUSEBATTERY_SDK"
    return
  fi
  # Prefer a Command Line Tools SDK matching the installed compiler. The
  # default SDK can be newer than the compiler on machines without Xcode.
  local candidate
  for candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.3.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.1.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  xcrun --sdk macosx --show-sdk-path
}

SDK="$(choose_sdk)"
if [[ ! -d "$SDK" ]]; then
  echo "找不到 macOS SDK：$SDK" >&2
  echo "可以用 MOUSEBATTERY_SDK=/path/to/MacOSX.sdk 指定。" >&2
  exit 1
fi

ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="${MIN_MACOS:-13.0}"
CACHE="$BUILD/.cache"
mkdir -p "$BUILD" "$CACHE/clang" "$CACHE/home"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$SRC" -name '*.swift' | sort)

BINARIES=()
for arch in $ARCHS; do
  target="$arch-apple-macos$MIN_MACOS"
  out="$BUILD/.obj-$arch/MouseBattery"
  mkdir -p "$BUILD/.obj-$arch"
  echo "编译 $arch …"
  HOME="$CACHE/home" swiftc -O -whole-module-optimization \
    -sdk "$SDK" -target "$target" \
    -module-cache-path "$CACHE/clang" \
    "${SOURCES[@]}" -o "$out" \
    -framework IOKit -framework AppKit -framework SwiftUI \
    -framework UserNotifications -framework ServiceManagement
  BINARIES+=("$out")
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$BUILD/MouseBattery"
else
  cp "${BINARIES[0]}" "$BUILD/MouseBattery"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/MouseBattery" "$APP/Contents/MacOS/MouseBattery"
chmod +x "$APP/Contents/MacOS/MouseBattery"

if [[ -f "$ROOT/../build/icon.icns" ]]; then
  cp "$ROOT/../build/icon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>小鼠电量</string>
  <key>CFBundleExecutable</key><string>MouseBattery</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>小鼠电量</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 小鼠电量</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "警告：ad-hoc 签名失败，应用仍可本机运行。" >&2
}

echo "已生成：$APP"
echo "架构：$(lipo -archs "$APP/Contents/MacOS/MouseBattery")"
echo "大小：$(du -sh "$APP" | cut -f1)"
