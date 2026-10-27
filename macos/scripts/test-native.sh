#!/bin/bash
# Run protocol/parser tests without SwiftPM (plain swiftc works with CLT only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/BattBar/Sources"
BUILD="$ROOT/build"
mkdir -p "$BUILD" "$BUILD/.cache/clang" "$BUILD/.cache/home"

SDK="${BATTBAR_SDK:-}"
if [[ -z "$SDK" ]]; then
  for candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.3.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.1.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; do
    if [[ -d "$candidate" ]]; then SDK="$candidate"; break; fi
  done
fi
[[ -n "$SDK" ]] || SDK="$(xcrun --sdk macosx --show-sdk-path)"

# The protocol types now delegate to the Rust core, so the tests need it too.
CORE="$ROOT/../core"
CORE_INCLUDE="$CORE/battbar-ffi/include/battbar_core.h"
CORE_LIB_DIR="$BUILD/.core"
mkdir -p "$CORE_LIB_DIR"
if ! command -v cargo >/dev/null 2>&1; then
  echo "找不到 cargo：测试需要 Rust 工具链来构建协议核心。" >&2
  exit 1
fi
cargo build --manifest-path "$CORE/Cargo.toml" --release \
  --package battbar-ffi --target aarch64-apple-darwin
cp "$CORE/target/aarch64-apple-darwin/release/libbattbar_ffi.a" "$CORE_LIB_DIR/libbattbar_ffi.a"

FILES=(
  "$SRC/Core/CoreBridge.swift"
  "$SRC/Providers/Models.swift"
  "$SRC/Providers/HIDSupport.swift"
  "$SRC/Providers/ATKProtocol.swift"
  "$SRC/Providers/ATKProvider.swift"
  "$SRC/Providers/RazerProtocol.swift"
  "$SRC/Providers/RazerProvider.swift"
  "$SRC/Providers/BluetoothProvider.swift"
  "$SRC/App/AppSettings.swift"
  "$ROOT/BattBar/Tests/main.swift"
)

HOME="$BUILD/.cache/home" swiftc -Onone -g \
  -sdk "$SDK" -target arm64-apple-macos13.0 \
  -module-cache-path "$BUILD/.cache/clang" \
  -import-objc-header "$CORE_INCLUDE" \
  -L "$CORE_LIB_DIR" -lbattbar_ffi \
  "${FILES[@]}" -o "$BUILD/BattBarTests" \
  -framework IOKit -framework Foundation

"$BUILD/BattBarTests"
