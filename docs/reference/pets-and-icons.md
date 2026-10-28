# Pets and session icons

Codex pets, session icon CLI, appearance security. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Pets: `/cmux-maestro-native:maestro-pet`

Active agent's pinned details show animated Codex-format pet (1536×1872 PNG/WebP,
8×9 cells of 192×208). Legacy sheets have width a multiple of 8, 512-4096,
and height from `ceil(9 * 208 * width / 1536)` through `2 * width`.
A v2 pet (1536×2288) works; legacy tails are ignored. A fixed 20-row mood atlas
also works, with width 512-1536, a multiple of 8, and height exactly
`ceil(20 * 208 * width / 1536)` (standard 1536×4160).
Every agent starts with bundled, original **Maestro** robot-head
pet. Animation follows state: idle, working, needs input, turn finished, blocked/failed.
Collect pets: while an agent uses an agent-made pet, hover its footer pet and click the centered **+** to
save it to your shared pets (the picker has the same **+** on agent-made cells and a confirmed **×**
on collected ones). Every agent's picker lists the whole collection. Removing a collected pet makes
agents using it fall back to their own pet or Maestro. Click pet to open picker: bundled pet, pets you saved or uploaded, pet
this agent made for itself. **Upload pet…** accepts Codex pet folder (`pet.json` plus
spritesheet) or bare sheet. Picker also links to online Codex pet galleries.

Bundled `maestro-pet` skill ships `pet_kit.py`: a Python standard-library drawing kit
(shapes, alpha, PNG writer). Any Copilot session in CMUX with Maestro's integration
draws its own original pet with no image provider, API key, network or package
install. Kit requires every frame of the five rows Maestro plays, fills unused Codex
rows from idle, and writes `pet.json`, `spritesheet.png` and `preview.png` to a new
folder. It never selects a pet. Agent adds pet with
`cmux-maestro-orchestrator pet --self --session-id … --add <folder>`. Command validates
format. It selects pet only after native identity helper proves session ownership.
Agent-made pet is **scoped to that session**. Use **Save to my pets** in picker to
keep it for every agent. Precedence: your choice, then agent's choice, then Maestro.
**Reset to default** chooses Maestro as your choice, so it wins over the agent's
pet until reset. **Reset to agent's pet** removes your choice. **Hide pet** /
**Show pet** applies to that session only; a hidden footer pet shows a small
sparkle that still opens the picker. Choices and hidden state follow the exact
session UUID across pane moves and app restarts; a replacement session in the
same pane starts fresh. Agent hover cards show the hovered session's own pet
and hidden state, never the active agent's. Row **Appearance > Choose pet…**
opens the same picker for that exact session; activity-only children, status-only
sessions, terminals and browsers have no pet. Reduce Motion shows still frame.

Pet playback uses a bounded render-server frame sequence at seven frames per second,
not a SwiftUI timeline. Working rings and input glows also animate in layers.
Hidden or detached native views remove their animations; changing the pet or state
replaces its sequence. No frame tick publishes evidence or requests sidebar layout.

### Mood atlas contract

The 20-row format preserves rows 0-8. Row 9 is Startled; row 10 is reserved.
Partial extensions are refused. No manifest version bump or companion asset:
new Maestro reads legacy pets, but older Maestro rejects mood atlases.
Bundled Maestro authors all 15 moods in the 20-row atlas. Its decoded RGBA rows
0-8 remain byte-identical to the original nine-row asset. The extra expressions
change faces and poses, not UI badges. Startled has wide white eyes, an O mouth,
a lifted head, sweat and antenna sparks; Needs permission's raised palm differs
from Question. This art does not change today's five-state selection or add the
separate mood/evidence resolver.

| Mood ID | Row | Frames | Legacy fallback row / frames |
| --- | --- | --- | --- |
| `idle` | 0 | 6 | 0 / 6 |
| `working` | 7 | 6 | 7 / 6 |
| `question` | 6 | 6 | 6 / 6 |
| `content` | 3 | 4 | 3 / 4 |
| `sad` | 5 | 8 | 5 / 8 |
| `startled` | 9 | 5 | 4 / 5 |
| `thinking` | 11 | 6 | 8 / 6 |
| `delegating` | 12 | 8 | 1 / 8 |
| `needs-permission` | 13 | 6 | 6 / 6 |
| `confused` | 14 | 6 | 8 / 6 |
| `compacting` | 15 | 6 | 2 / 8 |
| `sleepy` | 16 | 6 | 0 / 6 |
| `gone` | 17 | 6 | 0 / 6 |
| `proud` | 18 | 4 | 3 / 4 |
| `celebrating` | 19 | 5 | 4 / 5 |

Resolver seam: `SidebarPetSheet.Mood(rawValue:)` parses these IDs;
`SidebarPetSheet.playback(for:width:height:) -> SidebarPetSheet.Playback?`
returns `row` and `frameCount`, or `nil` for invalid geometry.
`SidebarPetStore.playback(petID:session:mood:)` resolves against the decoded sheet,
and `frame(petID:session:mood:index:)` crops it using that loop length.
Existing `state:` playback is unchanged. No mood/evidence resolver lives here.

Both formats retain the 10 MiB compressed limit. Extended width is capped before
native decoding, bounding the standard RGBA bitmap at 25,559,040 bytes, excluding
ImageIO overhead and cached crops. Legacy geometry retains its existing maximum
4096×8192 for compatibility; the new format does not increase that bound.
Top trim scans every playable mood or fallback cell, excluding reserved row 10.
Scaled cell origins round cumulatively, matching crop coordinates.

The kit's `PetSheet(moods=True)` generates all 20 rows and a 15-row preview.
Wholly undrawn mood rows copy the map's fallback; partly drawn rows fail.
Row 10 stays transparent. Native imports validate geometry and decoding, not
art quality or blank-row content. Draw distinct mood art when authoring a full atlas.

### Reproduce the bundled art

The original project's legacy drawing code remains in
`scripts/generate-maestro-pet.py`; `scripts/maestro_pet_art.py` draws the new
expressions with `pet_kit.Canvas`. A lossless WebP roundtrip retains the original
decoder's zero-alpha RGB behavior. Pillow is a **development-only** dependency;
the installed drawing kit remains standard-library-only. From the repository:

```sh
python3 -m venv .build/pet-art-env
.build/pet-art-env/bin/python -m pip install -r scripts/requirements-pet-art.txt
.build/pet-art-env/bin/python scripts/generate-maestro-pet.py
.build/pet-art-env/bin/python scripts/test-maestro-pet-art.py
python3 scripts/test-pet-kit.py
```

The generator writes only the selected output directory (default:
`CMUXMaestroSidebar/Pets`); it never installs or selects a pet. Pass a new output
directory to compare a regeneration before replacing checked-in assets.
Art tests pin the original decoded RGBA digest, require exact bundled WebP
reproduction, nonempty bounded frames and transparent reserved/unused cells.
Native collection tests render frame zero for all 15 moods at 38/46pt in
light/dark at 2x, compare exact pixels against explicit-row native references,
and reject identical bare frames. Contact sheets and individual references are
written under `.build/layout-validation/offscreen/pet-moods`. They are synthetic
offscreen evidence, not proof of hosted UI, live selection or mood resolution.

### Explicit offline copy upgrade

Only run on a **supplied** legacy PNG/WebP or pet folder, with the human's
direction. Never discover local pets or point output at an installed collection.
After preparing the development environment above:

```sh
.build/pet-art-env/bin/python scripts/upgrade-pet-moods.py \
  --source ./supplied-pet \
  --output ./upgraded-copy \
  --id example-mood-copy --name "Example Mood Copy"
```

The output must not exist, its parent must exist, and it must be outside the
source folder. Symlink inputs and manifest paths outside a direct child are
refused. Inputs must fully decode, be static PNG/WebP, at most 10 MiB, and use
legacy geometry at widths 512-1536 divisible by 8. Wider legacy pets are
explicitly refused rather than silently rescaled; a 20-row input is also refused.
Scaled and v2 inputs retain all decoded first-nine-row pixels; at fractional
cell heights new fallback crops alone may be nearest-neighbor fitted.

The new folder contains `pet.json`, `spritesheet.png`, `upgrade.json` with source
and legacy pixel hashes, a byte-for-byte `original-sheet.png` or
`original-sheet.webp`, and `original-pet.json` when supplied. V2 tails survive in
the untouched original and backup, not in reserved row 10. The source is never
written. Existing output is never replaced, including on a second invocation.
A write failure may leave a partial new folder; preserve it for inspection and
choose another new destination rather than retrying over it.

This is **generic fallback recomposition**, not automatic anatomy recognition:
new rows reuse old poses and may look identical. Inspect the copy, author
distinct expressions if desired, then separately use **Upload pet…** only with
human approval. Nothing in this command installs, chooses or updates local pets.
Local-pet rollout remains a separate approved operation.

## Choose your session icon: `/cmux-maestro-native:maestro-icon`

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
is `theme`, `green`, `teal`, `blue`, `purple`, `pink`, `red`, and `gray`; no orange.
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
sRGB, clamp to its gamut and round to eight bits per channel; alpha is discarded.
Custom glyphs have a one-point black or white outline, whichever contrasts more
with their fill, so even white on a light row or black on a dark row retains an
edge. Named colors and theme inheritance are unchanged. This is human-only:
`maestro_spawn`, `register`, `spawn` and `icon` still accept only the named
palette. The Python controller reads agent records, not either human color store;
its stored agent-color validation intentionally remains named-only.
The sidebar also rejects hex in agent `current.json` and version-1 `icons.json`;
accepting custom human preferences does not widen those decoded contracts.

### Agent appearance records

All new registrations and workers default to `md-robot`.
`register`/`spawn` accept optional `--icon` and `--color` startup choices.
Saved choices survive follow-ups. They are cosmetic: never refresh execution
or Git timestamps. Bounded, private `observer/icons.json` projection matches
node/run/workspace/surface identity. It survives older supervisors republishing
`current.json` without cosmetic fields. Sidebar stays read-only over its
existing observer-directory grant.

Managed rows, collapsed icon cards and session-icon details prefer the exact
session's `--self` appearance over the controller's startup choice, per glyph
and color. Before observation binds a running managed session, its freshly read
session appearance supplies the same choice. Human overrides still win;
**Reset to agent selection** removes only the human override. Names and renamed
surfaces never select an appearance record.

Glyph font and catalog are pinned to upstream commit
`b894ea7803af6aade63d60a4381e006098ec9c4d`. Hashes, upstream license and
glyph-source notices live under `Resources/NerdFonts/`. Tests check whole
selectable catalog against actual font outlines. Missing resources or unknown
stored glyphs show explicit unavailable indicators, not font fallback.

Refresh Copilot integration through stable app's existing explicit consent
flow to install new skill, controller and catalog. Cached CLI plugins are not
rewritten or restarted automatically.

Standalone Copilot sessions can use `icon --self --session-id <current-session-uuid>`
instead of orchestration credentials. Native helper verifies caller's
actual live CLI ancestor, PID/start tuple, in-use marker and existing binding.
It refuses another surface/session, stale or ambiguous proof. It never creates
an orchestration run. Appearance records stay under existing private
bindings grant, separate from ordinary hook refreshes. Malformed appearance
data cannot invalidate lifecycle evidence. No transcript or process arguments
are read for authorization.
