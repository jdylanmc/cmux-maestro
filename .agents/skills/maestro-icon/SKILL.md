---
name: maestro-icon
description: Choose a Nerd Font glyph and optional identity color for your own Maestro-managed session. Use when asked to pick or change your session icon, avatar, glyph, or color in the Maestro sidebar.
---

# Maestro Icon

Choose one icon for the invoking agent's own registered session. This changes
only its sidebar appearance. Never assign another session's icon, change
execution state, or create, recover, archive, rename, focus, or stop an agent.

## List the catalog

```sh
MAESTRO="$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator"
"$MAESTRO" icons --search ghost
"$MAESTRO" icons --search bug --limit 20
```

The pinned Nerd Fonts 3.5.1 catalog is the allowlist, not just the displayed
page or role presets. Use `--offset` to page results (maximum `--limit` is 100).
The response includes named presets, the font version, and matching glyph names,
characters and codepoints.

The [Nerd Fonts cheat sheet](https://www.nerdfonts.com/cheat-sheet) is a visual
reference. Accept its `nf-` names (`nf-fa-edge` becomes `fa-edge`), but validate
against the installed catalog: the website also lists removed glyphs.

Do not invent glyph names, accept image/font paths or URLs, edit observer files,
or modify the catalog. A role picture is cosmetic: it confers no privileges,
status, or orchestration role.
The response also lists allowed colors. Never accept arbitrary hex/CSS values.
Color affects the avatar, not execution-state colors. Omit color to retain the
current choice; use `theme` to restore the default.

## Resolve your own identity

- A managed worker uses its injected `CMUX_MAESTRO_WORKER_ID` and
  `CMUX_MAESTRO_CONTROL_TOKEN`.
- A coordinator uses only the coordinator ID and token returned by its own
  registration in this conversation. Verify the registration's workspace and
  surface match the current `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`.
- Never search control files, process arguments, shell history, another agent's
  output, or other sessions for credentials. Never infer identity from a title,
  working directory, selected tab, or recent session.
- If your own authenticated identity is unavailable, stop and report that
  `maestro-icon` currently requires a Maestro-managed session. Do not register
  or recover a run as a side effect. Standalone sessions are not yet supported.

## Pick and save

Honor an explicit requested glyph or preset. Otherwise choose one that fits your
current task, or use `md-robot` when no role-specific choice fits. Startup
defaults already exist; do not repeatedly change an icon on every turn.
Prefer genuine outline/line glyphs when a close equivalent exists; preserve
explicit glyph requests and use a filled fallback when no good outline exists.

For a managed worker:

```sh
"$MAESTRO" icon \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" \
  --token "$CMUX_MAESTRO_CONTROL_TOKEN" \
  --icon "md-bug_check" \
  --color "<palette-color>"
```

A coordinator uses its privately retained ID and token with the same command.
Never print or record the token in an answer, public log, or repository file.
Normal tool permissions still apply; do not request broad shell grants or
bypass a denied command just to change an icon.

Icon and color are independently optional, but supply at least one. Require
`ok: true` and the resolved canonical glyph name (`iconId`) and/or `iconColor`
in the response before reporting
the selection saved. A failure leaves the prior icon intact; report the error
without claiming a successful update.

The sidebar reads the saved icon on its next observer refresh (normally about
two seconds). This is not proof that a hidden or disconnected sidebar rendered
it. No session restart or provider action is needed. The choice survives
follow-up turns in the same managed session.

Choosing the `orchestrator` preset does not grant orchestration authority.
The runtime-derived row glow is independent of the chosen glyph and color:
working pulses subtly green, blocked is steady red, and idle does not pulse.
