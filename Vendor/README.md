# Vendored rhwp

`rhwp-f1f9c6a.tar.gz`: [rhwp](https://github.com/edwardkim/rhwp) `f1f9c6ae58344ee9368996d3543f76b9345cf227`, library crates and build assets only (MIT; NotoSansKR under SIL OFL, both inside the archive).

`scripts/prepare-engine.sh` verifies the checksum, extracts to `build/rhwp`, and applies `rhwp-layout.patch`:

- limits the workspace to the library crates;
- fixes missing line geometry around flow/inline pictures in table cells (anchoring, text exclusion, row height, duplicated prefix text);
- tries the installed `Pretendard Variable` before unrelated fallbacks for regular weight;
- makes `get_selection_rects_native`, `move_vertical_native` and the line-info queries public for the editor caret;
- builds the PDF font database once, maps each font file once, and remembers font picks per font specification (page PDF ~0.5 s → ~27 ms with the svg2pdf patch).

`svg2pdf-2caeb0a.crate`: the svg2pdf fork rhwp pins ([edwardkim/svg2pdf](https://github.com/edwardkim/svg2pdf) `2caeb0a`, MIT/Apache-2.0), packaged with `cargo package`. The script extracts it to `build/svg2pdf` and applies `svg2pdf.patch`, which resolves each glyph's font once per text element instead of cloning every font, and shares the font database's copy of a font file instead of copying it.

Private regression: `HWP_LAYOUT_FIXTURE=<report.hwp> cargo test -- --ignored` (never commit the input).
