# Native menu and warning matrix renders

[↑ Taskboard, layout, and visual validation](../layout-and-visual-validation.md) | [← Synthetic layout review images](synthetic-layout-review-images.md)

Retained native-menu tests capture complete production details popover at
explicit native 2x, including unavailable state after each identity change.
Unavailable heading and both explanatory lines must match an independent
runtime literal reference, pixel for pixel at expected locations: no OCR,
translation or pixel tolerance. Reference uses same native popover shell
for material/text rendering, not production text or a saved screenshot.
Blank-reference checks and light/dark missing, hidden, wrong, partially clipped
and misplaced warning controls exercise both embedded and native-popover captures.
All 12 retained-menu cases keep their identity, copy, attention, navigation and
pinned-subject assertions. Full captures and references use existing
`.build/layout-validation/offscreen/*.png` artifact path. Geometry and exact
pixel-difference sidecars remain beside them locally.

Full-sidebar warning matrix retains both densities, both appearances,
240x400/340x600-point sizes and both waiting/disconnected states (16 captures),
alongside connected-footer geometry and zero-painted host-clearance checks.
Only these natural-language warnings normalize OCR whitespace and lettercase:
`Waiting for CMUX` and `CMUX disconnected. Focus and live status unavailable.`
Both must retain every word and punctuation mark across line wraps. Empty, partial,
wrong-state, navigation-only, substituted-word and missing-punctuation controls
must reject. Each render reports its filename and recognized lines. Exact model,
session-ID, copy and inspector-pixel oracles do not use this normalization.

All metadata is synthetic. Local preferences are isolated for render
tests. Embedded render windows stay offscreen. Native interaction/popover tests
show only their own synthetic windows. These are view captures, not a desktop capture, live
CMUX-host visual proof, system VoiceOver verification or a checked-in OS/font
golden-image comparison. No transcripts, real workspace paths or desktop images are uploaded.
