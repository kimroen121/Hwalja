# Generated public fixtures

`generated.hwp` and `generated.hwpx` are project-owned documents generated from
rhwp `DocumentCore::create_blank_document_native`, with a single inserted text
paragraph: `HwpStudio generated fixture — 한글 읽기 전용`.
They contain no private sample documents or redistributed fonts.

Regenerate with `HWP_WRITE_FIXTURES=1 cargo test --manifest-path Engine/Cargo.toml
--locked -p hwp-engine-abi generated_hwp_and_hwpx_produce_owned_pdf_snapshots`.
The engine tests open both serialized formats through the public C ABI and
validate PDF headers and page counts; hosted Swift tests validate PDFKit parsing.
