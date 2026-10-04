# Pinned downstream rendering engine

`rhwp-f1f9c6a.tar.gz` contains the library source and required build assets
from https://github.com/edwardkim/rhwp at
`f1f9c6ae58344ee9368996d3543f76b9345cf227` (MIT; LICENSE inside archive).
The included NotoSansKR font is under the included SIL Open Font License.
No private school documents are included.

`scripts/prepare-engine.sh` verifies the source checksum, extracts under
ignored `build/rhwp`, then applies the reviewable `rhwp-layout.patch`.
The patch limits workspace members to the library crates and fixes missing
line-geometry table cases: flow-picture anchoring/text exclusion, inline
picture row height, and repeated text in a continuation owning a picture.
Stored-layout paths are intentionally left unchanged where possible.

The Hancom Docs screenshot follow-up also routes missing-line cell paragraphs
with paragraph-relative TopAndBottom flow pictures through real-width text
composition (not the legacy 45-character fallback). A single-picture host's
positive offset shares its existing text prefix instead of appending that
prefix twice. This also covers multiple qualifying pictures sharing a vertical
band; mixed controls and disjoint bands retain their existing behavior.
Measurement and partial-table painting apply the same helper.
The local regression checks the observed width, text-before-image order, and
absence of a large gap below single and paired images. A user-supplied six-page
Hancom PDF now supplies the local comparison: the report is six pages after
removing the paired-image duplicate prefix. Page-boundary, font, and border
differences remain; matching page count does not establish full fidelity.

This is a limited downstream fix, not a claim of full Hancom fidelity.
Regular Pretendard rendering also tries the installed `Pretendard Variable`
family before unrelated fallback fonts. Bold retains the existing fallback:
the SVG-to-PDF backend otherwise renders the variable font's regular instance
instead of a bold instance. No font files are copied from the user's library.
The app tests include an opt-in local physics-report regression through
`HWP_LAYOUT_FIXTURE`; never commit that input. Upstream's full fixture suite
is not shipped in this library-only archive.
