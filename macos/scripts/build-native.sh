#!/bin/bash
# Build the native macOS menu bar app. Requires Xcode Command Line Tools only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/BattBar/Sources"
BUILD="$ROOT/build"
APP="$BUILD/BattBar.app"
VERSION="${VERSION:-2.3.0}"
VERSION="${VERSION#v}"
BUNDLE_ID="com.battbar.app"

choose_sdk() {
  if [[ -n "${BATTBAR_SDK:-}" ]]; then
    printf '%s\n' "$BATTBAR_SDK"
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
  echo "可以用 BATTBAR_SDK=/path/to/MacOSX.sdk 指定。" >&2
  exit 1
fi

ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="${MIN_MACOS:-13.0}"
CACHE="$BUILD/.cache"
mkdir -p "$BUILD" "$CACHE/clang" "$CACHE/home"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$SRC" -name '*.swift' | sort)

# The protocol core lives in Rust (core/). Build it as a static library for each
# architecture and link it into the app, so the bundle stays a single binary with
# no runtime dependency.
CORE="$ROOT/../core"
CORE_INCLUDE="$CORE/battbar-ffi/include/battbar_core.h"
CORE_LIB_DIR="$BUILD/.core"
mkdir -p "$CORE_LIB_DIR"

if ! command -v cargo >/dev/null 2>&1; then
  echo "找不到 cargo：构建 Rust 核心需要 Rust 工具链（https://rustup.rs）。" >&2
  exit 1
fi

rust_target_for() {
  case "$1" in
    arm64|aarch64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "$1-apple-darwin" ;;
  esac
}

CORE_LIBS=()
for arch in $ARCHS; do
  rust_target="$(rust_target_for "$arch")"
  echo "构建 Rust 核心（${rust_target}）…"
  cargo build --manifest-path "$CORE/Cargo.toml" --release \
    --package battbar-ffi --target "$rust_target"
  CORE_LIBS+=("$CORE/target/$rust_target/release/libbattbar_ffi.a")
done

if [[ ${#CORE_LIBS[@]} -gt 1 ]]; then
  lipo -create "${CORE_LIBS[@]}" -output "$CORE_LIB_DIR/libbattbar_ffi.a"
else
  cp "${CORE_LIBS[0]}" "$CORE_LIB_DIR/libbattbar_ffi.a"
fi

BINARIES=()
for arch in $ARCHS; do
  target="$arch-apple-macos$MIN_MACOS"
  out="$BUILD/.obj-$arch/BattBar"
  mkdir -p "$BUILD/.obj-$arch"
  echo "编译 $arch …"
  HOME="$CACHE/home" swiftc -O -whole-module-optimization \
    -sdk "$SDK" -target "$target" \
    -module-cache-path "$CACHE/clang" \
    -import-objc-header "$CORE_INCLUDE" \
    -L "$CORE_LIB_DIR" -lbattbar_ffi \
    "${SOURCES[@]}" -o "$out" \
    -framework IOKit -framework AppKit -framework SwiftUI \
    -framework UserNotifications -framework ServiceManagement
  BINARIES+=("$out")
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$BUILD/BattBar"
else
  cp "${BINARIES[0]}" "$BUILD/BattBar"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/BattBar" "$APP/Contents/MacOS/BattBar"
chmod +x "$APP/Contents/MacOS/BattBar"

if [[ -f "$ROOT/../build/icon.icns" ]]; then
  cp "$ROOT/../build/icon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>BattBar</string>
  <key>CFBundleExecutable</key><string>BattBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>BattBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 BattBar</string>
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
echo "架构：$(lipo -archs "$APP/Contents/MacOS/BattBar")"
echo "大小：$(du -sh "$APP" | cut -f1)"
