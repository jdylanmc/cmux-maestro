# Choose your session icon

Part of [Pets and session icons](../pets-and-icons.md). Previous page is [Reproduce the bundled art and upgrade copies](reproduce-the-bundled-art.md). Next page is [Agent appearance records](agent-appearance-records.md).

Bundled `/cmux-maestro-native:maestro-icon` skill searches local Nerd Fonts catalog. It saves
glyph and/or identity color for **the invoking session only**.
Workers use injected identity/token. Coordinators use own retained
registration credentials. Command checks caller's exact workspace and
surface. It accepts no other-session target. It does not rename, focus, register,
recover, archive, approve, stop, or grant tools to any agent.

```sh
MAESTRO="$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator"
"$MAESTRO" icons --search ghost
"$MAESTRO" icons --search bug --limit 20 --offset 0
"$MAESTRO" icon \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" \
  --token "$CMUX_MAESTRO_CONTROL_TOKEN" \
  --icon nf-md-bug_check --color teal

# Standalone session: use the exact UUID from this CLI session's own context.
"$MAESTRO" icon --self --session-id "<current-session-uuid>" \
  --icon md-robot --color teal
```

[Cheat sheet](https://www.nerdfonts.com/cheat-sheet) is visual reference.
`nf-` prefixes and preset names are accepted. They resolve to canonical glyph
names. Removed, empty, or unsupported glyphs are rejected. Previous selection stays unchanged.
Searches are paged, capped at 100 results. Palette
is `theme`, `green`, `teal`, `blue`, `purple`, `pink`, `red`, and `gray`, with no orange.
Omit glyph or color to preserve that part of selection.

### Human color picker

Every **Choose icon** popover (sessions, terminals and browsers, including row
**Appearance** actions) keeps the named swatches and adds **Custom…**, a native
macOS color well that opens the system color panel. Choose or enter any opaque
sRGB hex. The well displays the current color; a checkmark marks a custom
selection and its accessibility label includes the hex. Custom changes preview
in the native well and panel, then save once when the panel closes or the well
deactivates, only if the canonical color changed. **Done** finishes the pending
color before closing. Named swatches still save immediately. Both reset actions
keep their existing precedence; either reset explicitly cancels an open custom edit,
even when the resulting color is unchanged.
Clicking a named swatch also cancels any pending custom edit, including when
choosing the already-selected swatch.

Human choices stay in the sidebar container's `sidebar-icons.json`, never in
agent appearance records. Version 2 stores color as a named string or uppercase
`#RRGGBB`. Named-only choices continue writing version 1. Version 2 is written
only while a custom hex remains in that file; removing the last custom color
returns to version 1. Older builds reject version 2, show their existing
preference notice and preserve the file until an explicit global reset.
Downgrading therefore hides preferences only in files containing custom colors;
upgrading restores them. Unknown versions and malformed colors are never
overwritten by ordinary edits.

The panel has no opacity control. Wide-gamut and grayscale choices convert to
sRGB, clamp to its gamut and round to eight bits per channel. Alpha is discarded.
Custom glyphs have a one-point black or white outline, whichever contrasts more
with their fill, so even white on a light row or black on a dark row retains an
edge. Named colors and theme inheritance are unchanged. This is human-only:
`maestro_spawn`, `register`, `spawn` and `icon` still accept only the named
palette. The Python controller reads agent records, not either human color store;
its stored agent-color validation intentionally remains named-only.
The sidebar also rejects hex in agent `current.json` and version-1 `icons.json`;
accepting custom human preferences does not widen those decoded contracts.
