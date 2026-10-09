---
name: joe-mode-cmux
description: "Human-only session Joe-mode cockpit in CMUX. Reconcile one repository controller, launch pinned Maestro workers, and arrange PM, Discovery, stacked developers, and support without claiming unattended execution."
disable-model-invocation: true
user-invocable: true
---

# Joe-mode CMUX

Run Joe-mode as a visible, interactive CMUX cockpit. This is an adapter around
[Joe-mode](../joe-mode/SKILL.md), not another project-management policy or
controller. The human-authored [intent](intent.md) defines its purpose.

Use Joe's [delivery pace](../joe-mode/DELIVERY-PACE.md) and
[invoker doctrine selection](../doctrine/APPLY.md#joe-review-operations).

Read [LAYOUT](LAYOUT.md) before changing CMUX topology and [RUNTIME](RUNTIME.md)
before registering or spawning through Maestro. Apply Joe-mode's
[runtime guidance](../joe-mode/RUNTIME.md), shared
[team contract](../joe-mode-paseo/TEAM.md), and
[agent lifecycle](../squadron/LIFECYCLE.md). Independent writing deliveries
still follow [worktree placement](../ship/WORKSPACE.md), and pull-request
handoffs still follow [delivery readiness](../ship/DELIVERY.md) and
[Shepherd observation](../shepherd/OBSERVATION.md).

Use [Joe role worktrees](../joe-mode/WORKTREES.md): Project Manager stays on
`main`, Discovery uses `discovery/<feat>`, and an explicitly authorized
PR/auto-merge coordinator uses `pr-sniper`. Fast-forward clean owned main
when remote main changes and after each confirmed merge. All role worktrees
remain in the same CMUX workspace; pass their exact paths to Maestro.

## Entry and ownership

**Human activation only.** Installing, discovering, restoring, or mentioning
this package does not start it. Once activated, it remains the session's
Joe-mode presentation until the human pauses, stops, or re-anchors it.

Resolve the repository, anchor, selected backlog, scope, exclusions, tracker,
and human authority exactly as Joe-mode requires. Reconcile the same repository
owner board with session Joe-mode and
[Joe-mode Paseo](../joe-mode-paseo/SKILL.md) and
[Joe-mode Orca](../joe-mode-orca/SKILL.md) before registering CMUX or
dispatching. There is one logical controller per repository across these
entrypoints. Join the existing controller or obtain observed release and
acknowledged transfer. Unknown ownership blocks activation.

The invoking conversation remains Project Manager and owns the human
conversation. Do not invoke another Joe-mode controller. Use Joe-mode's current
local routing sections directly under this adapter's human grant.

## Activate the cockpit

1. Verify the Project Manager is in the selected repository's owned `main`
   checkout and reconcile remote main using the guarded worktree procedure.
   Read its guidance and current owner board. Never switch or reset a dirty
   delivery checkout to manufacture main placement.
2. Verify exact caller identity and all blocking checks in [RUNTIME](RUNTIME.md):
   this conversation must already be a managed coordinator with native peer
   and launch tools. Missing communication blocks activation, not merely layout.
3. Reuse its exact managed identity; do not register another owner. Present it
   as `PM · Joe Mode` using the `project-manager` [role appearance](#role-appearance)
   only through explicitly authorized supported owned metadata operations.
   Preserve human appearance choices and keep control tokens private.
4. Inspect the existing workspace tree. Reconcile the four areas from
   [LAYOUT](LAYOUT.md) additively when [RUNTIME](RUNTIME.md)'s placement
   capability passes, without creating a new workspace/window, stealing focus,
   or mutating an unowned surface. Otherwise keep managed workers beside the
   Project Manager and report the degraded layout.
5. Rename the repository workspace and publish an `active` Joe status only
   after ownership, CMUX identity, and Maestro readiness are verified.
6. Verify that the peer tools actually work in this session. Registration does
   not make the Project Manager a recipient. Do not replace missing native
   communication with human relay or generic harness helpers.
7. Complete one useful bounded Joe-mode pass now: refresh the selected work,
   launch needed roles, and report actual dispatch, blockers, or human waits.
   A layout alone is not an activated team.

## Place useful roles

Keep one interactive Discovery owner when the anchor has unsettled product,
architecture, requirements, or planning questions. Its blue compass surface
stays in the Discovery pane while waiting for the human when placement is
supported; otherwise it remains beside the Project Manager. Do not create
several workers asking competing questions.

Launch developers only for selected non-overlapping delivery assignments.
Every launch uses native `maestro_spawn`, verified parent-account inheritance,
the launch-default/preference contract in [RUNTIME](RUNTIME.md), and a complete
first task. Resolve its explicit operational role through
[role appearance](#role-appearance) before constructing the launch packet.
When [RUNTIME](RUNTIME.md)'s placement capability is verified, move the
returned exact surface into the developer pane and stack additional developers
there as tabs. Otherwise leave workers beside the Project Manager and report
the degraded layout. Name each worker for its delivery at spawn. Sharing a pane
does not permit sharing a writing worktree.

Launch one Shepherd with the canonical `shepherd` appearance while accepted
pull-request duties exist. Put it in Support when placement is supported; otherwise leave it beside
the Project Manager. Support may also display review, test, log, or preview
surfaces. Do not create an idle Shepherd merely to fill the pane.

Respect the current human-authorized staffing budget and the installed
[runtime preflight](RUNTIME.md#capacity-preflight) together. Joe's generic
six-developer default is not a ceiling over an explicit scoped human budget;
the runtime-first cohort authorizes up to twelve concurrent implementation
workers plus useful support, only within verified runtime/resource room.
Reserve capacity for PM, Discovery, Shepherd and independent review before
dispatch. Installed behavior must be checked: the qualified source defaults
to 32 live workspace sessions, but merged source is not an installed upgrade.
Older installed controllers may still have a global 128-node history bound;
#167-capable source separates workspace history from bounded host protection.
Never substitute either product ceiling for the human dispatch budget or infer
free slots from completion/close acceptance. Retained and uncertain managed
resources still count. Ordinary non-agent previews/logs are not managed workers.

## Role appearance

[role-appearance.json](role-appearance.json) is the ONE authoritative local
mapping for prospective role metadata. [role-appearance.py](role-appearance.py)
prepares only `icon`/`color` fields; it never launches, edits live metadata,
changes settings or grants permissions. Use the explicit operational role key,
not a guessed role from a title or directory.

For every applicable Joe/Maestro role launch, including nested review and
authorized PR coordination, resolve appearance BEFORE its one `maestro_spawn`
call. Use this same selector when preparing a prospective role handoff:

```sh
python3 "<joe-mode-cmux skill directory>/role-appearance.py" --role roast
python3 "<joe-mode-cmux skill directory>/role-appearance.py" --role pr-sniper
```

Supply `--icon`/`--color` only for explicit human choices or authorized
carry-forward appearance in the launch plan. Each supplied field wins over its
default; unspecified fields retain the canonical role defaults. PR Sniper has
no new color default. Shepherd retains the preexisting local green color;
only its glyph changes. Unlisted roles keep supplied metadata without inventing
new defaults. Other existing role defaults remain unchanged.

Merge the resulting fields into the SAME launch assignment (`name`, `cwd`,
`task`, and independently authorized policy). Verify the loaded tool declares
`icon`/`color` and the exact glyph resolves through its supported catalog;
unsupported appearance is a reported blocker, not a substituted icon.
The helper is offline metadata preparation, not installed capability proof.
Source tests verify glyph resolution and sanitized metadata, not live rendering.

An existing session's role handoff does NOT authorize a metadata retrofit,
relaunch or adoption. Preserve its current human choices and include the
prospective role appearance/effects in the handoff; only a separate explicit
owned metadata grant permits an actual change. Appearance communicates role,
not readiness, authority, ownership or accepted work.

## Route work through Joe-mode

Use Joe-mode's backlog, Discovery, planning, Ship, Patch, Refactor, Roast,
Verify, and Shepherd routes without duplicating them here. Preserve their human
decisions, publication gates, independent review, permissions, ownership,
worktrees, and merge boundaries.

Every nested role retains the Maestro runtime contract, including support and
blocker investigation. Never substitute an SDK/task agent, even after native
launch failure. Report truthful prepared/launching/failed states instead of
counting those assignments as a running visible team.

The cockpit changes presentation, not authority:

- role names, icons, colors, statuses, progress, and logs never prove success;
- worker launch does not prove task completion;
- terminal exit does not prove accepted work;
- CMUX restoration does not prove live supervision;
- the adapter does not grant tracker writes, approval, merge, production, or
  destructive authority.

Use CMUX status and logs for verified coordination events. Notify the human only
for decisions, material blockers, or pull requests ready for final review.
Keep routine chatter in role surfaces.

## Reconcile and continue

Use Maestro `status`, the Joe owner board, Git/provider state, and actual
artifacts to reconcile outcomes. Use the separately installed `/maestro`
guide for native peer discovery, one fire-and-forget follow-up, and ordinary
replies when this session participates. The Project Manager cannot inject
terminal input or silently read worker conversations. A send is not a receipt,
custody transfer, or task completion; verify the returned evidence and artifacts
under the selected Joe route. When a worker needs human input, identify its
exact tab and surface. Missing native tools do not permit route-file inspection
or a keystroke fallback.

Continue bounded Joe-mode passes while this human conversation remains active.
Do not promise work between turns or after the session ends. If unattended
recurring operation is requested, stop and offer the separately authorized
Paseo or Orca adapter with its own verified wake contract; never invent CMUX scheduling.

On pause or stop, follow Joe-mode ownership transfer and Maestro lifecycle
rules. Preserve active deliveries and Shepherd custody. Close interactive
sessions normally before archive; never kill processes, delete terminals, or
discard work to make the UI look clean.
