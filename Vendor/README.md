# Vendored rhwp

`rhwp-f1f9c6a.tar.gz`: [rhwp](https://github.com/edwardkim/rhwp) `f1f9c6ae58344ee9368996d3543f76b9345cf227`, library crates and build assets only (MIT; NotoSansKR under SIL OFL, both inside the archive).

`scripts/prepare-engine.sh` verifies the checksum, extracts to `build/rhwp`, and applies `rhwp-layout.patch`:

- limits the workspace to the library crates;
- fixes missing line geometry around flow/inline pictures in table cells (anchoring, text exclusion, row height, duplicated prefix text);
- tries the installed `Pretendard Variable` before unrelated fallbacks for every requested weight;
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
- grows the last line for an object after the paragraph's last character, aligns an object-only line that was re-laid as its paragraph says, stands its pictures' bottoms on the baseline, and lays every object of an empty paragraph on its line (only the first was drawn);
- draws a treat-as-character equation of a paragraph split over pages only on the page holding its line (it was drawn again on the next).
- reads 한글's `from` / `to` limits (`sum from {i=1} to {n}`; LaTeX's `\to` stays an arrow), keeps whole keywords such as `SIMEQ` together, draws check, acute, grave, dyad, arch and strike-through decorations as themselves, and draws ∬, ∭ and the contour integrals at the size their layout gives, with a slimmer integral sign and its limits closer;
- adds `insert_new_number_of_native` for 새 번호로 시작 of every 번호 종류 (쪽·그림·표·수식·각주·미주), and makes 책갈피 넣기 shift the characters after it instead of adding a bogus character offset (the 책갈피 read back at the paragraph end).
- draws equations in STIX Two Math (its math italic letters for variables) and takes the integral, radical, bracket, arrow and accent signs from that font, grown by its MATH table's size variants and part assemblies, the layout giving radicals, brackets and integrals the glyphs' widths; 상호 관계 arrows span what is written over and under them;
- tags each equation group, on the page and in the preview, with its script, layout box, size and color, so the app can set it with SwiftMath;
- fits fallback color emoji glyphs to their HWP layout advances so consecutive emoji do not paint over one another or the caret.
- refreshes the per-line indentation flag after paragraph reflow, so a section-leading paragraph applies new first-line and hanging indents instead of inheriting stale stored geometry.
- adds `line_place_native`: the page, column and line in that column showing a line of a body paragraph, for the 상황 선.
- pastes inline HTML with no block (part of a paragraph, as browsers copy it) as one paragraph with its formats, and reads `<b>`, `<i>` and `<u>` with attributes (`<b style=…>`, as Safari copies).
- puts a click in a 머리말 or 꼬리말 at the nearest character boundary (it landed one character to the right).
- adds `flip_table_native` for 표 뒤집기: mirrors across the rows or columns, swaps rows and columns, and turns by 90 or 180 degrees, merged cells included, each line going with its side and, if asked, the 안 여백 too.
- keeps the line of a white box with a thin black line inside a group (the default 직사각형, drawn by 한글); only a text-only box's line is still dropped.
- charges the layout-drift safety margin only once when a paragraph is split across pages, including documents whose line records must be rebuilt.
- marks edited header/footer line records as synthetic, so a short justified last line no longer inherits the imported-only rule that stretches its words to both edges.
- persists 문단 번호의 `새 번호 목록 시작` as a cloned numbering definition and matching paragraph-shape references, so its start value survives both HWP and HWPX save/reopen.
- reads and writes 쪽 테두리/배경's 첫 쪽 제외 as HWPX `HIDE_FIRST` (it took `HIDE_ALL`), and leaves the border or background off a section's first page when it is set.
- numbers a section's pages from its 구역 설정 시작 쪽 번호 (사용자, or the next odd or even number), hides the 머리말 and 꼬리말 on a section's first page when it says so, renumbers 그림, 표 and 수식 after a section definition changes, and makes `assign_auto_numbers` public.
- adds `get/apply_note_shape_native` for 각주 모양 as well as 미주 모양 (leaving the numbers to the caller, and taking 구분선 길이's 5 cm, 2 cm, ⅓ and full-column values), and draws every 번호 모양 (circled letters and 자모, 갑을병, 甲乙丙, *†‡§ and the rest) in the body's mark and the note's own number alike.
- moves 스타일 추가·편집·지우기 from the wasm API into `DocumentCore` (`style_list_native`, `update_style_native`, `update_style_shapes_native`, `relink_style_native`, `create_style_native`, `delete_style_native` with a replacement style) and adds `move_style_native`; deleting and moving renumber the paragraphs in cells, text boxes, captions, notes, 머리말 and 꼬리말 too.
- adds `replace_font_native` for 문서 정보 › 글꼴 정보's 글꼴 바꾸기: every 글자 모양 using a font in one 언어 (or all) takes another, and the document is laid out again.
- opens `set_cell_zone_properties_native` to callers outside the crate, for 셀 테두리/배경's 하나의 셀처럼 적용.
- lets `set_table_properties_native` take the table's own 테두리/배경 (표 테두리/배경), laid over the border fill it has.
- 개체 속성: drawing objects take 그림자 투명도; pictures read and write their 선 종류, and HWPX keeps a picture's `<hp:lineShape>`; SVG draws a drawing object's 그림자 as the shape moved by its offset, under it.
- 셀·표 배경: border fills take a 그러데이션 or 그림 from JSON and give them back, are reused only when their whole fill matches, keep a 그림's 밝기 and 대비 the right way round in HWPX, and a table's own 테두리/배경 no longer overwrites every cell's; `register_embedded_bin_data` is public.

`svg2pdf-2caeb0a.crate`: the svg2pdf fork rhwp pins ([edwardkim/svg2pdf](https://github.com/edwardkim/svg2pdf) `2caeb0a`, MIT/Apache-2.0), packaged with `cargo package`. The script extracts it to `build/svg2pdf` and applies `svg2pdf.patch`, which resolves each glyph's font once per text element instead of cloning every font, and shares the font database's copy of a font file instead of copying it.

Private regression: `HWP_LAYOUT_FIXTURE=<report.hwp> cargo test -- --ignored` (never commit the input).
