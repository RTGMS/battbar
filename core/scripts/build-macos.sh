#!/bin/bash
# Build the Rust core as a static library for the macOS Swift app and verify the
# C ABI links. The macOS app itself is not modified by this script; it only
# produces the artifact that a future integration step would link.
#
#   core/scripts/build-macos.sh            # host architecture
#   core/scripts/build-macos.sh universal  # arm64 + x86_64, lipo'd together
#
# Output: core/target/macos/libbattbar_ffi.a
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/core/target/macos"

# Prefer a Rust toolchain that actually has the tool we need. A system-wide
# rustup whose home is not writable by the build user is a common setup, so the
# caller may point RUSTUP_HOME/CARGO_HOME anywhere writable.
if command -v cargo >/dev/null 2>&1; then
  CARGO_BIN="$(command -v cargo)"
else
  echo "找不到 cargo，请先安装 Rust（https://rustup.rs）。" >&2
  exit 1
fi

MODE="${1:-host}"

mkdir -p "$OUT"

build_arch() {
  local target="$1"
  # Progress goes to stderr so that the function's stdout stays a clean path.
  echo "==> cargo build ($target, release)" >&2
  "$CARGO_BIN" build --manifest-path "$ROOT/core/Cargo.toml" \
    --release --package battbar-ffi --target "$target" >&2
  echo "$ROOT/core/target/$target/release/libbattbar_ffi.a"
}

case "$MODE" in
  universal)
    ARM_LIB="$(build_arch aarch64-apple-darwin)"
    X86_LIB="$(build_arch x86_64-apple-darwin)"
    lipo -create "$ARM_LIB" "$X86_LIB" -output "$OUT/libbattbar_ffi.a"
    ;;
  host)
    ARCH="$(uname -m)"
    # uname reports arm64, while Rust calls the same target aarch64.
    case "$ARCH" in
      arm64|aarch64) RUST_TARGET="aarch64-apple-darwin" ;;
      x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
      *) echo "不支持的架构: $ARCH" >&2; exit 1 ;;
    esac
    LIB="$(build_arch "$RUST_TARGET")"
    cp "$LIB" "$OUT/libbattbar_ffi.a"
    ;;
  *)
    echo "用法: $0 [host|universal]" >&2
    exit 2
    ;;
esac

echo "==> $OUT/libbattbar_ffi.a"
lipo -info "$OUT/libbattbar_ffi.a" 2>/dev/null || true

# Compile and run the Swift smoke test against the freshly built library.
# The clang module cache must be redirected into the repo: the default location
# (~/Library/Caches or /var/folders) is not always writable from a sandboxed
# build, which breaks bridging-header compilation.
echo "==> Swift FFI smoke test" >&2
mkdir -p "$OUT/.cache/clang" "$OUT/.cache/home"
HOME="$OUT/.cache/home" swiftc -Onone \
  -module-cache-path "$OUT/.cache/clang" \
  -import-objc-header "$ROOT/core/battbar-ffi/include/battbar_core.h" \
  -L "$OUT" -lbattbar_ffi \
  "$ROOT/core/scripts/ffi-smoke.swift" \
  -o "$OUT/ffi-smoke"
"$OUT/ffi-smoke"
