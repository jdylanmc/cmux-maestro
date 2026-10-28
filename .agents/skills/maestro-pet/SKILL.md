---
name: maestro-pet
description: Make, add and choose a Codex-compatible pet for your own Copilot session in Maestro. Draws an original pet with the bundled dependency-free pet_kit.py (Python standard library only), then selects it for this session only until the human saves it for reuse.
---

# Maestro Pet

Installed invocation: `/cmux-maestro-native:maestro-pet`.

Every agent starts with the bundled **Maestro** robot-head pet. Use this skill only
when you or the human want your own session to show a different Codex pet. It changes
your session's sidebar appearance only. Never choose another session's pet, change
execution state, or create, recover, archive, rename, focus, or stop an agent.

## Ownership rules

- A pet you add is **scoped to this session**. It is not shared and not saved to the
  human's pet repository. The human can click your pet in the sidebar and choose
  **Save to my pets** to keep it for other agents; never do that for them.
- A human choice in the sidebar always wins over yours. They can reset to your pet at
  any time; never fight their choice by reselecting.
- Do not repeatedly change your pet. Pick one that fits the session, or keep Maestro.

## Resolve your own identity

Use the exact session UUID from your current CLI session context (for example your own
session-state directory name). Never guess a recent session, search other sessions,
read private binding files, capabilities or tokens, or infer identity from a title,
directory or selected tab. If you cannot establish your own session UUID, stop and
explain; report that no pet changed.

```sh
MAESTRO="$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator"
SESSION="<your-exact-current-session-uuid>"
```

## See what is available

```sh
"$MAESTRO" pets --session-id "$SESSION"
```

The response lists the default (`maestro`) and any pets this session already added.

## Make a new pet

A valid Codex pet is a folder with `pet.json` and a transparent PNG or WebP
spritesheet of **1536x1872** pixels: 8 columns x 9 rows of 192x208 cells. Rows
in order: idle, running-right, running-left, waving, jumping, failed, waiting, running,
review. Legacy sheets use 8 columns of 192:208 cells (width a multiple of 8,
512-4096; height from `ceil(9 * 208 * width / 1536)` through `2 * width`). A **v2** pet
(`spriteVersionNumber` 2, 1536x2288, 11 rows) adds look-direction rows below those; the
extra rows are ignored. A **20-row mood atlas** uses exactly
`ceil(20 * 208 * width / 1536)` pixels of height, with width a multiple of 8,
512-1536 (standard **1536x4160**). Other tall or partial extensions are refused.
The mood width cap bounds decoded pixels; both formats retain the 10 MB file limit.
No `pet.json` version change or companion asset is needed. New Maestro reads old
sheets; older Maestro cannot read the 20-row format.
`--add` refuses a sheet that does not fully decode with macOS ImageIO (`sips`), even when its header is valid.
Maestro shows `idle`, `running` (working), `waiting` (needs input), `waving`
(turn finished) and `failed` (blocked or failed).

If the human gave you a pet folder or sheet, skip to "Add and choose". Otherwise draw
one yourself; no human approval, image provider, API key, network or package install
is needed.

This skill ships `pet_kit.py` next to this file (Python 3.9+ standard library only).
Set `SKILL_DIR` to the **loaded skill's base directory**; do not assume a source
checkout. Write your drawing script and output in your **session artifacts**,
never inside `SKILL_DIR`, Maestro's files or the human's pet collection.

```python
import sys
sys.dont_write_bytecode = True          # keep the installed skill folder clean
sys.path.insert(0, "<SKILL_DIR>")
from pet_kit import PetSheet, MAESTRO_STATES

sheet = PetSheet()
for state, count in MAESTRO_STATES:     # idle 6, waving 4, failed 8, waiting 6, running 6
    for i in range(count):
        f = sheet.frame(state, i)        # transparent 192x208 canvas, origin top-left
        bob = 3 if i % 2 else 0
        f.ellipse(96, 128 + bob, 50, 54, "#5fb3ff")      # body
        f.ellipse(78, 112 + bob, 8, 10, "#ffffff")        # eyes
        f.ellipse(114, 112 + bob, 8, 10, "#ffffff")
        # f.rect(x0, y0, x1, y1, c)  f.polygon([(x, y), ...], c)  f.line(x0, y0, x1, y1, c, width)
print(sheet.save("<new-output-folder>", "<pet-id>", "<Display Name>", "<short description>"))
```

- Colors: `"#rgb"`, `"#rrggbb"`, `"#rrggbbaa"` or `(r, g, b[, a])`. Later shapes draw on top.
- Draw **every frame** of the five `MAESTRO_STATES`; the kit refuses empty ones. Other
  Codex rows are optional; undrawn ones reuse the idle loop so the sheet stays valid.
- Make states distinct: gentle idle bob, `waving` raises an arm, `failed` slumps or
  shows an X, `waiting` looks up or shows `?`, `running` (working) shows busy motion
  in place. Keep the character inside the cell with a few pixels of margin.
- Original artwork only: never copy proprietary or third-party characters unless the
  human supplied the art and has the right to use it.
- `save` refuses an existing folder, invalid IDs and the reserved `maestro` ID. It
  writes `pet.json`, `spritesheet.png` and an opaque `preview.png` of the five rows.
  **View `preview.png`** and fix anything clipped, blank or unreadable before adding.

### Optional mood rows

Use `PetSheet(moods=True)` for a 20-row atlas. Draw the same five required
`MAESTRO_STATES`, then optionally draw every frame of each extra state in
`MOOD_STATES` (imported from `pet_kit`). The preview includes all 15 state/mood
rows, in `MAESTRO_STATES + MOOD_STATES` order. Row 10 is reserved, not drawable.
Wholly undrawn mood rows copy their explicit fallback below; partially drawn rows
are refused. Fallbacks may look alike: draw distinct art when expressing moods.
Imported 20-row sheets must contain usable art; the reader does not detect blank rows.

| State passed to `frame` | Row | Frames | Nine-row fallback |
| --- | --- | --- | --- |
| `startled` | 9 | 5 | 4 jumping |
| `thinking` | 11 | 6 | 8 review |
| `delegating` | 12 | 8 | 1 running-right |
| `needs-permission` | 13 | 6 | 6 waiting |
| `confused` | 14 | 6 | 8 review |
| `compacting` | 15 | 6 | 2 running-left (8 frames) |
| `sleepy` | 16 | 6 | 0 idle |
| `gone` | 17 | 6 | 0 idle |
| `proud` | 18 | 4 | 3 waving |
| `celebrating` | 19 | 5 | 4 jumping |

Rows 0-8 remain unchanged. The fallback uses the old row's full frame count,
not the extended row's count. Mood playback is a format capability; today's
sidebar still selects only the five existing states. Bundled Maestro now authors all
15 moods in a 20-row sheet; that art does not introduce a mood/evidence resolver.

For expressive art, draw every `MOOD_STATES` frame rather than relying on fallback.
Use face and pose changes, not UI badges: Startled can use wide white eyes, an O
mouth and a lifted pose; Thinking can hold its chin; Needs permission can raise a
stop palm, distinct from Question's upward glance; Confused can use asymmetric
eyes; Compacting can squeeze inward; Sleepy can close its eyes; Gone can use a
vacant silhouette; Proud and Celebrating should differ in pose. Keep each loop's
first frame recognizable at **38pt and 46pt in both light and dark**, including
Reduce Motion's still frame. Inspect bare frames without labels too.

Existing supplied pets are not automatically rewritten. The source checkout's
`scripts/upgrade-pet-moods.py` is an explicit offline **copy** upgrade, documented
in `docs/reference/pets-and-icons.md`. It preserves originals/backups and uses
generic fallback poses, not inferred facial expressions. Never scan or rewrite
the human's collection, select the copy, or replace a human choice without their
separate direction.

## Add and choose

```sh
# add a pet folder (or a bare spritesheet image) and choose it for this session
"$MAESTRO" pet --self --session-id "$SESSION" --add "<new-output-folder>"

# choose a pet already added to this session, or return to the default
"$MAESTRO" pet --self --session-id "$SESSION" --pet-id "<id>"
"$MAESTRO" pet --self --session-id "$SESSION" --pet-id maestro
```

The command validates the format and size, copies the pet into this session's private
area, and selects it only after the native helper proves you own the session. Require
`ok: true` and the returned `petId` before reporting the pet saved. A failure leaves the
prior pet intact; report the error without claiming success, and do not try to bypass a
denied command or write pet files yourself.

The sidebar reads the saved choice on its next refresh (about two seconds). That is not
proof that a hidden or disconnected sidebar rendered it. The choice lasts for this
session; tell the human they can click the pet to **Save to my pets** for reuse.
