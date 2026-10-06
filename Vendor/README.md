# Vendored rhwp

`rhwp-f1f9c6a.tar.gz`: [rhwp](https://github.com/edwardkim/rhwp) `f1f9c6ae58344ee9368996d3543f76b9345cf227`, library crates and build assets only (MIT; NotoSansKR under SIL OFL, both inside the archive).

`scripts/prepare-engine.sh` verifies the checksum, extracts to `build/rhwp`, and applies `rhwp-layout.patch`:

- limits the workspace to the library crates;
- fixes missing line geometry around flow/inline pictures in table cells (anchoring, text exclusion, row height, duplicated prefix text);
- tries the installed `Pretendard Variable` before unrelated fallbacks for regular weight;
- makes `get_selection_rects_native`, `move_vertical_native` and the line-info queries public for the editor caret, and `show_transparent_borders` for 투명 선;
- builds the PDF font database once, maps each font file once, and remembers font picks per font specification (page PDF ~0.5 s → ~27 ms with the svg2pdf patch);
- exposes that font database (`default_fontdb`, `fontdb`) so the editor's display lists pick the faces PDF export picks.
- lets text go in after the controls standing at an offset (`set_insert_skip`, `Paragraph::insert_text_after_controls`), so typing right after an inline picture or equation stays after it;
- moves character shapes back with the text when a control is deleted (they stayed put, shifting formatting after an object by eight units);
- lets the cell-path delete take an equation or drawing object as well as a picture;
- adds `get_char_properties_in_footnote_native` and `apply_char_format_in_footnote_native`, as the header and footer have, for 글자 모양 inside notes;
- builds the text a drawing object takes on (`set_text_box_at`) like a new 글상자's, and lays the section out again;
- draws 문단 번호 shape 10 (ㄱ, ㄴ, ㄷ), which fell back to digits;
- writes a new picture caption as `그림 ` + number + space, as table and drawing-object captions are written (it was an empty paragraph).
- lays out a paragraph saved without line records that holds only an object in the line (a display equation), as it does one with text, and stands each equation of a re-laid line on its own baseline (the line takes the larger part above and below it);
- reads the equation shorthands `+-` (±), `-+` (∓) and `:=`, draws `<=`, `>=`, `!=` and the other two-character symbols as their signs, and puts `UNDEROVER`'s limits under and over its base;
- draws equations as 한글 does: a minus sign for `-`, space around relations and binary operators (none for a sign), subscripts a quarter of the size below the baseline, lowercase Greek in italic, Times New Roman first and Times widths for spacing;
- grows the last line for an object after the paragraph's last character, and aligns an object-only line that was re-laid as its paragraph says.

`svg2pdf-2caeb0a.crate`: the svg2pdf fork rhwp pins ([edwardkim/svg2pdf](https://github.com/edwardkim/svg2pdf) `2caeb0a`, MIT/Apache-2.0), packaged with `cargo package`. The script extracts it to `build/svg2pdf` and applies `svg2pdf.patch`, which resolves each glyph's font once per text element instead of cloning every font, and shares the font database's copy of a font file instead of copying it.

Private regression: `HWP_LAYOUT_FIXTURE=<report.hwp> cargo test -- --ignored` (never commit the input).
