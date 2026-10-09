#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$repo_root/Vendor/rhwp-1a76570.tar.gz"
patch_file="$repo_root/Vendor/rhwp-layout.patch"
expected=dbaf950b2303e53ea1c8b410153a57a9be32a7f64b48d963e601773e5950a407
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
previous=""
if [[ -e "$destination" ]]; then
  previous="$(mktemp -d "$repo_root/build/rhwp-previous.XXXXXX")"
  mv "$destination" "$previous/source"
fi
mv "$staging" "$destination"
[[ -z "$previous" ]] || rm -rf "$previous"
