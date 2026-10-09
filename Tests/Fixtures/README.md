# Generated public fixtures

`generated.hwp` and `generated.hwpx` are project-owned documents generated from
rhwp `DocumentCore::create_blank_document_native`, with a single inserted text
paragraph: `hwalja generated fixture — 한글 읽기 전용`.
They contain no private sample documents or redistributed fonts.

Regenerate with `HWP_WRITE_FIXTURES=1 cargo test --manifest-path Engine/Cargo.toml
--locked -p hwp-engine-abi generated_fixtures_open_as_display_lists`.
The engine tests open both serialized formats through the public C ABI and
validate PDF headers and page counts; hosted Swift tests validate PDFKit parsing.

`locked.hwp` is the engine's plain test document saved locked with the password
`1234` (regenerate with `HWP_WRITE_FIXTURES=1 cargo test ... a_document_locked`).
