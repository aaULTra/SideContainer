#!/bin/bash
# Builds the Rust FFI for device and simulator and repackages
# SideInstallerFFI.xcframework. Run on any rust-core/ change, then regenerate
# the project with `xcodegen generate`.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
# Match the app's deployment floor, or cc-rs objects trip linker warnings.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.4}"
# Make Cargo visible to non-login shells only when needed. CI already exports
# the toolchain path; re-sourcing its generated shell setup under nounset can
# abort Bash before any diagnostics, even with `|| true` and hidden stderr.
if ! command -v cargo >/dev/null 2>&1 && [[ -r "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "Cargo is not on PATH. Install Rust or load its shell environment before building." >&2
  exit 1
fi

# Rewrite $HOME to /build, since Rust bakes absolute source paths in as string
# constants that survive stripping and reach the app's log console.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Repackaging SideInstallerFFI.xcframework"
rm -rf "$ROOT/SideInstallerFFI.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libsideinstaller_ffi.a -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/libsideinstaller_ffi.a -headers rust-core/include \
  -output "$ROOT/SideInstallerFFI.xcframework"

echo "==> Done. (Re)generate the project with: xcodegen generate"
