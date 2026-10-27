#!/bin/bash
# Replay core/vectors/vectors.json against the shipped macOS Swift code.
#
# Compiles the protocol sources together with a tiny driver (no SwiftPM needed,
# same approach as macos/scripts/test-native.sh) and exits non-zero when the
# Swift implementation disagrees with the shared vectors.
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

FILES=(
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
  "${FILES[@]}" -o "$OUT/swift-crosscheck" \
  -framework IOKit -framework Foundation

BATTBAR_VECTORS="$ROOT/core/vectors/vectors.json" "$OUT/swift-crosscheck"
