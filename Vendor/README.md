# Vendored rhwp

`rhwp-f1f9c6a.tar.gz`: [rhwp](https://github.com/edwardkim/rhwp) `f1f9c6ae58344ee9368996d3543f76b9345cf227`, library crates and build assets only (MIT; NotoSansKR under SIL OFL, both inside the archive).

`scripts/prepare-engine.sh` verifies the checksum, extracts to `build/rhwp`, and applies `rhwp-layout.patch`:

- limits the workspace to the library crates;
- fixes missing line geometry around flow/inline pictures in table cells (anchoring, text exclusion, row height, duplicated prefix text);
- tries the installed `Pretendard Variable` before unrelated fallbacks for regular weight;
- makes `get_selection_rects_native` public for the editor's selection highlight.

Private regression: `HWP_LAYOUT_FIXTURE=<report.hwp> cargo test -- --ignored` (never commit the input).
