#!/bin/bash
# Hardware-in-the-loop test: real HID traffic through the Rust core.
#
# Builds the core static library, then compiles a harness that reads an actual
# report from the ATK receiver over IOKit and decodes it twice — once with the
# shipped Swift implementation, once with the Rust core — and compares them.
#
#   core/scripts/hardware-test-macos.sh
#   BATTBAR_HW_ITERATIONS=20 core/scripts/hardware-test-macos.sh
#
# Requires a plugged-in ATK / VXE / MAD 2.4G receiver for the ATK section; the
# Razer and Bluetooth sections report "skipped" when no device is present.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/macos/BattBar/Sources"
OUT="$ROOT/core/target/hardware"
mkdir -p "$OUT/.cache/clang" "$OUT/.cache/home"

echo "==> 构建 Rust 核心静态库" >&2
if ! bash "$ROOT/core/scripts/build-macos.sh" >/dev/null; then
  echo "构建核心失败，先修好构建再跑真机测试。" >&2
  exit 1
fi

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

# Only the pieces the harness needs: the Swift oracle, the HID helpers, and the
# device descriptors used for enumeration.
cp "$ROOT/core/scripts/hardware-macos.swift" "$OUT/main.swift"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

echo "==> 编译真机测试程序" >&2
HOME="$OUT/.cache/home" swiftc -Onone \
  -sdk "$SDK" -target "$TARGET" \
  -module-cache-path "$OUT/.cache/clang" \
  -import-objc-header "$ROOT/core/battbar-ffi/include/battbar_core.h" \
  -L "$ROOT/core/target/macos" -lbattbar_ffi \
  "$SRC/Providers/Models.swift" \
  "$SRC/Providers/HIDSupport.swift" \
  "$SRC/Providers/ATKProtocol.swift" \
  "$SRC/Providers/RazerProtocol.swift" \
  "$SRC/Providers/ATKProvider.swift" \
  "$SRC/Providers/RazerProvider.swift" \
  "$SRC/Providers/BluetoothProvider.swift" \
  "$OUT/main.swift" \
  -o "$OUT/hardware-test" \
  -framework IOKit -framework Foundation
if [[ ! -x "$OUT/hardware-test" ]]; then
  echo "编译失败，未生成可执行文件。" >&2
  exit 1
fi
rm -f "$OUT/.built"

echo "==> 运行" >&2
echo ""
"$OUT/hardware-test"
