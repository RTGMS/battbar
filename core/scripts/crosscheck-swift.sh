#!/bin/bash
# Replay core/vectors/vectors.json through the Swift types the app ships.
#
# Since the macOS app now delegates to the Rust core over the C ABI, this
# verifies the *binding*: that the Swift wrappers surface the vector results
# correctly (status mapping, error mapping, value conversion). Independent
# agreement of a separately written implementation is covered by
# crosscheck.mjs, which still exercises the JavaScript code path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/macos/BattBar/Sources"
OUT="$ROOT/core/target/swift-crosscheck"
mkdir -p "$OUT/.cache/clang" "$OUT/.cache/home"

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

# The Swift protocol types call into the Rust core, so link it.
CORE="$ROOT/core"
mkdir -p "$OUT/.core"
cargo build --manifest-path "$CORE/Cargo.toml" --release \
  --package battbar-ffi --target "$(uname -m | sed 's/arm64/aarch64/')-apple-darwin" \
  >&2
cp "$CORE/target/$(uname -m | sed 's/arm64/aarch64/')-apple-darwin/release/libbattbar_ffi.a" \
  "$OUT/.core/libbattbar_ffi.a"

FILES=(
  "$SRC/Core/CoreBridge.swift"
  "$SRC/Providers/Models.swift"
  "$SRC/Providers/HIDSupport.swift"
  "$SRC/Providers/ATKProtocol.swift"
  "$SRC/Providers/RazerProtocol.swift"
  "$SRC/Providers/BluetoothProvider.swift"
  "$OUT/main.swift"
)

# Swift only allows top-level statements in a file literally named main.swift,
# so the driver is copied under that name instead of being renamed in the repo.
cp "$ROOT/core/scripts/swift-crosscheck.swift" "$OUT/main.swift"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

HOME="$OUT/.cache/home" swiftc -Onone \
  -sdk "$SDK" -target "$TARGET" \
  -module-cache-path "$OUT/.cache/clang" \
  -import-objc-header "$CORE/battbar-ffi/include/battbar_core.h" \
  -L "$OUT/.core" -lbattbar_ffi \
  "${FILES[@]}" -o "$OUT/swift-crosscheck" \
  -framework IOKit -framework Foundation

BATTBAR_VECTORS="$ROOT/core/vectors/vectors.json" "$OUT/swift-crosscheck"
