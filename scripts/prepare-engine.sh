#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$repo_root/Vendor/rhwp-f1f9c6a.tar.gz"
patch_file="$repo_root/Vendor/rhwp-layout.patch"
expected=cee30df3302e4839cf55b6cb2cfa8cceda192a3d39e14a287e963ddc28795855
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Engine source checksum mismatch' >&2; exit 1; }
stamp="$expected-$(shasum -a 256 "$patch_file" | awk '{print $1}')"

# svg2pdf (rhwp's PDF writer), packaged from the fork rhwp pins, with its own patch.
svg2pdf_archive="$repo_root/Vendor/svg2pdf-2caeb0a.crate"
svg2pdf_patch="$repo_root/Vendor/svg2pdf.patch"
svg2pdf_stamp="$(cat "$svg2pdf_archive" "$svg2pdf_patch" | shasum -a 256 | awk '{print $1}')"
svg2pdf_destination="$repo_root/build/svg2pdf"
if [[ ! -f "$svg2pdf_destination/.hwpstudio-$svg2pdf_stamp" ]]; then
  mkdir -p "$repo_root/build"
  svg2pdf_staging="$(mktemp -d "$repo_root/build/svg2pdf-prepare.XXXXXX")"
  tar -xzf "$svg2pdf_archive" -C "$svg2pdf_staging" --strip-components 1
  patch --batch -d "$svg2pdf_staging" -p1 < "$svg2pdf_patch"
  touch "$svg2pdf_staging/.hwpstudio-$svg2pdf_stamp"
  rm -rf "$svg2pdf_destination"
  mv "$svg2pdf_staging" "$svg2pdf_destination"
fi

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
