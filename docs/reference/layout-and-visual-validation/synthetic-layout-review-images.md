# Synthetic layout review images

[↑ Taskboard, layout, and visual validation](../layout-and-visual-validation.md) | [← Sidebar order and layout storage](sidebar-order-and-layout-storage.md) | [Native menu and warning matrix renders →](native-menu-and-warning-matrix-renders.md)

`./scripts/test.sh` writes offscreen SwiftUI/AppKit PNGs to
`.build/layout-validation/offscreen/`. CI uploads only those PNGs as the
**sidebar-layout-offscreen** artifact (14-day retention), including when tests
fail after producing images. Review both densities at 240 pixels in dark mode,
increased contrast, and long synthetic path/model/nested-label scenarios. Also review
light-mode expansion matrix at 240 and 349 pixels. Dedicated
`managed-*-340x600.png` and `unmanaged-light-340x600.png` fixtures exercise two
workspaces, duplicate names, nested ancestry, long branches and mixed lifecycle
states at target sidebar density. Broader matrix uses a 941-point
viewport. Filenames identify density, scenario, view mode and width.
Renderer checks actual SwiftUI color-scheme and contrast environment.
Per-image JSON records measured scroll viewport/document geometry. Metadata-only
panels also render at both widths to check horizontal containment. Clarity
validation uses matched before/after fixtures, not screenshots of live work.
Its fixed synthetic clock also owns injected freshness timer. Elapsed CI
wall time cannot expire a fixture whose logical clock has not advanced.
Clarity tests also render light/dark icon and status keys, verify each
symbol exists, and confirm output contains actual color accents.
Contrast uses SDK's writable `_colorSchemeContrast` backing key only in
tests, paired with native high-contrast AppKit appearances. No system display
preferences change.

Active-window footer renders all eight light/dark, 240/340-point width and
144/220-point height combinations at explicit native 2x resolution. Exact model
and copy-feedback text is recognized from those pixels without resampling or
language correction. Copy feedback also retains native accessibility and
viewport-containment checks. Wrong, missing, hidden and clipped model controls
must fail the same visibility check. Each text failure reports its image and
recognized lines.
Separate inspector uses native 2x production captures in both appearances.
An independently rendered runtime literal `Model` / `verified-model` pair uses
same compact font and selectable-text modifiers. Every pixel of both lines,
their borders and trailing column must match exactly. Allow only one-pixel
translation. No resizing, OCR spelling aliases or averaged ink score.
Blank references fail explicitly. Wrong, missing, hidden, partially clipped,
wrong-model-with-the-right-value-elsewhere and suffixed values must reject through
same oracle. PNG references/captures and per-image pixel differences remain
with render artifacts. Revoked-subject clearing, no-copy and passive-focus
checks remain in place. Footer OCR and native copy checks unchanged.
