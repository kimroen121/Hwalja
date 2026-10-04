#!/bin/bash
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export CFLAGS="${CFLAGS:-} -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$repo_root/scripts/prepare-engine.sh"
for tool in cargo cbindgen lipo; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
mkdir -p "$repo_root/build"
engine_targets="${HWP_ENGINE_TARGETS:-aarch64-apple-darwin}"
for target in $engine_targets; do
  cargo build --manifest-path "$repo_root/Engine/Cargo.toml" --locked --release -p hwp-engine-abi --target "$target"
done
engine_archives=()
for target in $engine_targets; do
  engine_archives+=("$repo_root/Engine/target/$target/release/libhwp_engine_abi.a")
done
lipo -create "${engine_archives[@]}" -output "$repo_root/build/libhwp_engine_abi.a"
cbindgen --quiet --config "$repo_root/Engine/crates/hwp-engine-abi/cbindgen.toml" \
  --crate hwp-engine-abi "$repo_root/Engine" --output "$repo_root/Engine/include/HwpEngineABI.h"
