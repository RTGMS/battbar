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

FILES=(
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
  "${FILES[@]}" -o "$BUILD/BattBarTests" \
  -framework IOKit -framework Foundation

"$BUILD/BattBarTests"
