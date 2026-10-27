#!/bin/bash
# Run every check for the Rust core and its cross-language contracts.
#
#   core/scripts/test-all.sh
#
# Requirements: Rust (cargo, rustfmt, clippy), Node.js 24+, macOS with Xcode
# Command Line Tools for the Swift cross-check. Each step is skipped with a
# warning when its tool is missing, so this stays usable on a Windows box that
# only runs cargo.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILED=0

step() {
  local label="$1"
  shift
  echo ""
  echo "== $label"
  if "$@"; then
    echo "-- ok"
  else
    echo "-- FAILED"
    FAILED=1
  fi
}

has() { command -v "$1" >/dev/null 2>&1; }

if has cargo; then
  step "cargo fmt --check" cargo fmt --manifest-path "$ROOT/core/Cargo.toml" --all --check
  step "cargo clippy" cargo clippy --manifest-path "$ROOT/core/Cargo.toml" --offline --all-targets -- -D warnings
  step "cargo test" cargo test --manifest-path "$ROOT/core/Cargo.toml" --offline
else
  echo "跳过 Rust 检查：找不到 cargo。" >&2
fi

if has node; then
  step "JavaScript cross-check" node "$ROOT/core/scripts/crosscheck.mjs"
else
  echo "跳过 JS 对拍：找不到 node。" >&2
fi

if [[ "$(uname -s)" == "Darwin" ]] && has swiftc; then
  step "Swift cross-check" bash "$ROOT/core/scripts/crosscheck-swift.sh"
  step "Swift FFI smoke test" bash "$ROOT/core/scripts/build-macos.sh"

  # Hardware tests need a real receiver, so they are opt-in. `test-all.sh --hw`
  # (or BATTBAR_HW=1) runs them; CI never has the device.
  if [[ "${BATTBAR_HW:-0}" == "1" ]] || [[ "${1:-}" == "--hw" ]]; then
    step "Real hardware (ATK/Razer/Bluetooth)" bash "$ROOT/core/scripts/hardware-test-macos.sh"
  else
    echo ""
    echo "== 真机测试"
    echo "-- 跳过（插着接收器时用 core/scripts/test-all.sh --hw 运行）"
  fi
else
  echo "跳过 Swift 对拍：需要 macOS + swiftc。" >&2
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "全部通过。"
else
  echo "有检查失败，见上方输出。" >&2
fi
exit $FAILED
