#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$repo_root/Vendor/rhwp-f1f9c6a.tar.gz"
patch_file="$repo_root/Vendor/rhwp-layout.patch"
expected=cee30df3302e4839cf55b6cb2cfa8cceda192a3d39e14a287e963ddc28795855
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Engine source checksum mismatch' >&2; exit 1; }
stamp="$expected-$(shasum -a 256 "$patch_file" | awk '{print $1}')"
destination="$repo_root/build/rhwp"
if [[ -f "$destination/.hwpstudio-$stamp" ]]; then exit 0; fi
mkdir -p "$repo_root/build"
staging="$(mktemp -d "$repo_root/build/rhwp-prepare.XXXXXX")"
tar -xzf "$archive" -C "$staging"
patch --batch -d "$staging" -p1 < "$patch_file"
touch "$staging/.hwpstudio-$stamp"
if [[ -e "$destination" ]]; then
  backup="$(mktemp -d "$repo_root/build/rhwp-previous.XXXXXX")"
  mv "$destination" "$backup/source"
fi
mv "$staging" "$destination"
