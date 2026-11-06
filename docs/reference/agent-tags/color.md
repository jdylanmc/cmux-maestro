# Color

[↑ Agent tags](../agent-tags.md) | [← Canonical slug and assignment](canonical-slug-version-1.md) | [Presentation →](presentation.md)

- **Automatic** (registry version 1): FNV-1a 32-bit over the slug's Unicode scalars;
  hue `hash % 360`, saturation `0.48 + ((hash >> 9) % 13) / 100`, lightness
  `0.64 + ((hash >> 17) % 9) / 100`, HSL to sRGB rounded per channel (the approved prototype's
  reference).
- **Human override**: one of 14 fixed swatches or **Custom…**, stored per slug in `sidebar-tags.json`, so it applies
  to every occurrence on every session. **Use automatic color** removes it. Editor color changes,
  like tag text, are written only on **Save**; **Cancel** discards both. Agents cannot set colors.
  Colors are fixed sRGB values. Light/dark appearance never changes them.
  Choosing a named swatch or **Use automatic color** cancels any pending system-panel
  edit before changing the draft, even when the resulting RGB is unchanged.
- **Custom…** opens the macOS system color panel, with opacity disabled. Any chosen or entered
  color converts to opaque, eight-bit sRGB (wide-gamut channels clamp), stored as uppercase
  `#RRGGBB`. The native well shows the current color; a checkmark marks a custom choice and its
  accessibility label includes the hex. The panel previews without writing; closing it updates
  the draft once, and only if its canonical color changed. **Save** or switching the edited tag
  finishes the pending color first; **Cancel** discards it. While active, the system panel is a
  child window of the editor's popover, preventing outside-click dismissal from losing the draft.
  If another window already owns the system panel, the well reports **Color unavailable**
  without detaching or closing that panel. After that window releases the panel, a successful
  retry clears the warning immediately.
- Human preference **format version 2** accepts named strings or `#RRGGBB`; version-1 named files
  read without writing. Named-only edits continue writing version 1; version 2 is written only
  while the file contains a custom hex. Removing the last custom color restores version 1.
  Older builds reject version 2,
  show the existing unavailable notice and preserve the file until an explicit global reset.
  Unknown versions or invalid colors also preserve the file. Slug rules, automatic palette,
  and the separate agent store remain version 1.
- Text is black or white, whichever contrasts more with the opaque chip background. Every automatic
  color (all 42,120 hue/saturation/lightness combinations) and every swatch is at least 4.5:1;
  tests check both the computed and the rendered pixels.
  For every opaque custom color with relative luminance `L`, black contrast is
  `(L + 0.05) / 0.05` and white contrast is `1.05 / (L + 0.05)`.
  Their product is 21, so the larger is at least `sqrt(21)`, approximately **4.58:1**.
  Tests sweep a 4,096-color sRGB grid and render boundary colors.
  See [WCAG relative luminance and contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).
