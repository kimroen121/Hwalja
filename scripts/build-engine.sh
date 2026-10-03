#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in cargo cbindgen lipo; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
mkdir -p "$repo_root/build" "$repo_root/Generated"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --manifest-path "$repo_root/Engine/Cargo.toml" --locked --release -p hwp-engine-abi --target "$target"
done
lipo -create "$repo_root/Engine/target/aarch64-apple-darwin/release/libhwp_engine_abi.a" \
  "$repo_root/Engine/target/x86_64-apple-darwin/release/libhwp_engine_abi.a" \
  -output "$repo_root/build/libhwp_engine_abi.a"
lipo "$repo_root/build/libhwp_engine_abi.a" -verify_arch arm64
lipo "$repo_root/build/libhwp_engine_abi.a" -verify_arch x86_64
cbindgen --config "$repo_root/Engine/crates/hwp-engine-abi/cbindgen.toml" \
  --crate hwp-engine-abi "$repo_root/Engine" --output "$repo_root/Generated/HwpEngineABI.h"
bash "$repo_root/scripts/check-header-paths.sh" < "$repo_root/Generated/HwpEngineABI.h"
