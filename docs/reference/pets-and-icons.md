# Pets and session icons

Codex pets, session icon CLI, appearance security. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Pets: `/cmux-maestro-native:maestro-pet`

Active agent's pinned details show animated Codex-format pet (1536×1872 PNG/WebP,
8×9 cells of 192×208). Sheets are accepted flexibly: 8 columns, at least nine rows, 192:208 cells at any whole-pixel scale (width a multiple of 8, 512 to 4096). A v2 pet (1536×2288) works. Extra rows are ignored. Every agent starts with bundled, original **Maestro** robot-head
pet. Animation follows state: idle, working, needs input, turn finished, blocked/failed.
Collect pets: while an agent uses an agent-made pet, hover its footer pet and click **+** to
save it to your shared pets (the picker has the same **+** on agent-made cells and a confirmed **×**
on collected ones). Every agent's picker lists the whole collection. Removing a collected pet makes
agents using it fall back to their own pet or Maestro. Click pet to open picker: bundled pet, pets you saved or uploaded, pet
this agent made for itself. **Upload pet…** accepts Codex pet folder (`pet.json` plus
spritesheet) or bare sheet. Picker also links to online Codex pet galleries.

Bundled `maestro-pet` skill wraps `hatch-pet` for creation. Agent adds pet with
`cmux-maestro-orchestrator pet --self --session-id … --add <folder>`. Command validates
format. It selects pet only after native identity helper proves session ownership.
Agent-made pet is **scoped to that session**. Use **Save to my pets** in picker to
keep it for every agent. Precedence: your choice, then agent's choice, then Maestro.
**Reset to agent's pet** removes your choice. Reduce Motion shows still frame.

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

All new registrations and workers default to `md-robot`.
`register`/`spawn` accept optional `--icon` and `--color` startup choices.
Saved choices survive follow-ups. They are cosmetic: never refresh execution
or Git timestamps. Bounded, private `observer/icons.json` projection matches
node/run/workspace/surface identity. It survives older supervisors republishing
`current.json` without cosmetic fields. Sidebar stays read-only over its
existing observer-directory grant.

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
