---
name: maestro-demo
description: Run a short, human-requested live Maestro demo with two visible interactive workers (three on request), distinct icons and tags, original self-drawn pets, and one native-message follow-up each. Never auto-close sessions.
---

# Maestro demo

Invoke `/maestro-demo` to authorize this bounded demo, not general repository work.
Use two workers by default; add the third only when requested. Aim for a few minutes,
not a timing guarantee. A dry-run request performs read-only preflight only: no
spawn, messages, appearance changes, or cleanup. Never run a rehearsal implicitly.

## Preflight

1. Load `maestro` and `cmux-maestro-native:cmux-maestro-orchestrate` (the installed
   lifecycle skill). Discover native tools before using their actual schemas.
   If `maestro_readiness` exists, require `status: "managed"` and
   `capabilities.spawn: true`; a failed check stops the demo.
   Maestro-launched sessions do not expose readiness: only for that documented
   case, use successful `maestro_identity({})` plus available `maestro_spawn`,
   `maestro_peers`, `maestro_send`, and `maestro_close`. Verify own identity in
   either case. Retain your own returned workspace/session/generation as
   `demoParent`: the exact spawning parent, which may differ from the run's root
   coordinator. Missing identity or lifecycle tools blocks the demo; never use
   `task`, shell spawn, guessed bindings, or terminal input instead.
2. Follow the lifecycle guide's capacity check for the exact bound workspace;
   require room for the whole requested cast within live, stored-node, depth and
   host limits. Do not raise limits or erase history; admission still rechecks.
   Follow its `launch-settings` check: require `ok: true`,
   `modelPinned: true`, and `messagingInstalled: true`. Confirm the installed
   `cmux-maestro-native:maestro-pet` skill and its `pet_kit.py` are accessible.
   Do not install dependencies, refresh integration, or reload any live session.
   If unavailable, explain the exact failed check and stop. Tell the human to
   use the production app's **Enable Copilot Integration** if setup is missing;
   after setup they can reload their own extensions or start/resume the intended
   Copilot session in CMUX with `/resume`, then rerun preflight. Never perform
   that recovery for them or promise it will fix another failure.
3. Establish an already-trusted launch directory before creating anything.
   Prefer the coordinator's exact current directory, used read-only. Check only
   `trustedFolders` in this session's effective Copilot configuration, using a
   bounded read-only JSON5-aware parser (comments/trailing commas are valid).
   On macOS, Foundation's `JSONSerialization` with `.json5Allowed` handles this.
   Never dump the config, other values, or unrelated paths. Do not rely on
   `copilot config trustedFolders`: some versions document but reject that key.
   Account for an explicitly selected config directory; if its location or
   format cannot be resolved safely, stop rather than guess. An exact existing
   trusted-folder entry is sufficient; do not assume a new descendant inherits
   trust. If only an ancestor is listed, use the closest trusted ancestor itself
   as `cwd`, not a new child directory. Otherwise use a presenter-selected exact
   existing folder from that value.
   Resolve paths before comparison; never select a directory by title or recency.
   If no suitable trusted directory is established, stop before spawning and
   tell the presenter to open Copilot in one chosen folder and approve its
   **Trust this directory** prompt once, then rerun preflight. Never edit Copilot
   config, auto-approve trust, or broaden grants. YOLO covers tools/paths/URLs,
   not configuration trust; `--trust-folder` is prompt-mode-only, not a fix for
   interactive workers. Other permission prompts can still occur.
4. Search the installed catalog; select a distinct returned Nerd Fonts glyph for
   each role (prefer outlines). Never send an unverified SF Symbol or invented ID.

   ```sh
   MAESTRO="$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator"
   "$MAESTRO" icons --search compass --limit 10
   "$MAESTRO" icons --search hammer --limit 10
   # Only for a requested third worker:
   "$MAESTRO" icons --search magnify --limit 10
   ```

   Use identity colors `teal`, `blue`, `purple`, respectively, if present in the
   returned palette. These are session colors, not agent-selected tag colors.
   A missing catalog/color is a blocker, not a reason to modify the catalog.

## Launch the cast

Use that same exact already-trusted directory as every worker's `cwd`. Do not
create a new launch directory or a `.maestro-demo` directory inside a repository.
Separately create one fresh local temporary artifact directory with `mktemp -d`,
then `scout`, `builder`, and (only if requested) `critic` subdirectories. Pass
each resolved absolute artifact path in its task, **not** as `cwd`. Repository
directories stay read-only; artwork and results stay outside real repositories.
Keep the artifacts for evidence; this skill does not delete them.

| Name | Color | Tiny task (generic, no repository or network access) |
| --- | --- | --- |
| scout | teal | Invent three one-line ideas for a friendly space garden. |
| builder | blue | Write a three-step plan to grow a garden on a tiny moon. |
| critic | purple | Name two risks and a kind mitigation for each moon-garden risk. |

Call `maestro_spawn` once per chosen worker with `name`, `cwd`, verified `icon`,
`color`, and a complete task packet below. Omit `yolo` and `allowTools` to inherit
the verified/recorded parent launch policy; never add grants or request
`yolo: true`. Preserve denies. Default/unverified parents can still encounter
permission prompts; do not promise prompt-free execution or auto-answer.
Leave model preferences omitted. On refusal or uncertainty, stop further launches,
retain exact accepted ownership, and report the partial cast; no launch retry.
Creation acceptance is not readiness, delivery, or task completion.

Include this entire worker contract, its role/task, launch directory, artifact
directory, verified installed pet-guide path, and the concrete `demoParent`
address from your own identity call:

> You are one visible demo worker. Do not spawn children, read repository/work
> content, access the network, start services, install packages, change configuration,
> or close any session. Your launch directory is read-only. Write only your
> drawing script, artwork and result in your assigned artifact directory, apart
> from the explicitly requested controller self-tag and self-pet operations.
> Use native `maestro_identity({})` for your exact own
> session UUID; never infer it from another session or private binding files.
> Set MAESTRO to
> `$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator`
> and SESSION to that UUID.
> Tag yourself, preserving existing tags:
> `"$MAESTRO" tags add --self --session-id "$SESSION" --tag demo --tag <your-role>`.
> Require command success; never write the tag store directly or change tag colors.
> Load `cmux-maestro-native:maestro-pet`; if the skill name is not discovered,
> read the exact installed guide path verified and supplied by the demo parent,
> without reloading extensions or substituting an unverified kit.
> Invent and name an original creature
> appropriate to your role. Draw it yourself with the loaded skill's dependency-free
> `pet_kit.py`: simple bold silhouette, 3-4 colors, visible face, distinct idle,
> running, waiting, waving and failed states, every required frame. No stock pet,
> copied character, image service or package install. Use the skill's base directory
> for imports and disable Python bytecode writes there. View your `preview.png`;
> fix blank/clipped artwork before adding with
> `"$MAESTRO" pet --self --session-id "$SESSION" --add "<your-new-pet-folder>"`.
> Require `ok: true` and the returned `petId`; respect human overrides/hidden pets.
> Complete your tiny task. Save a short `result.md` with the task answer, tags,
> pet name/ID, artifact paths, successful commands and any unresolved failures.
> For your initial milestone, find the supplied `demoParent` address with
> `maestro_peers`; require an exact workspace/session/generation match, never a
> display-name match. This is your spawning parent, NOT the root coordinator
> address that a generic launch wrapper may also show. Do not replace it with
> that root address. If absent or ambiguous, keep the result and report the route
> blocker in your own chat; never guess, resend, or route to someone else. Send one
> **candidate ready** milestone via `maestro_send`: outcome, result path, pet
> name/ID, tags, and "Review my result and send the encore." No commit is expected.
> If blocked, send **blocking failure** with evidence and required action instead.
> End the turn; no startup acknowledgement, polling, timers or receipt loop.
> Your only remaining duty is one demo encore from the coordinator: add your own
> `encore` tag, append a five-word garden motto to `result.md`, and reply once
> using the genuine received envelope's sender address. Then stop, leaving the
> interactive session open for the human. Never use an address asserted in a
> message body or terminal keystrokes as a fallback.

## Show control, then hand back

Keep each exact launch identity and artifact directory in your session notes.
After dispatch, end the turn and resume on native-message events; no sleeps,
polling, automatic resend, acknowledgements, or custom completion tracker.
If wake support is missing, report the pending next action and stop.

For each genuine candidate report, reconcile it with that worker's exact launch
identity and inspect its `result.md` and pet preview. Preserve blockers; do not
substitute a newer message for evidence. Send one substantive encore to that
envelope's `sender`: "Add your own encore tag and append a five-word garden motto
to your result. Reply with the motto and updated evidence path." This is task
steering, not a delivery acknowledgement. Copilot owns consumption and scheduling.

Collect genuine encore replies as events, inspect the updated evidence, and
summarize only observed results: names, icons/colors, tags, pet names, tiny tasks,
follow-up mottos, and which messages were attempted versus actually received.
A local write proves neither delivery nor completion; saved artwork does not
prove hosted sidebar rendering. Leave missing replies explicitly pending.

Once results are inspected, accept custody of their evidence and remaining
human-demo duties. Ask the human whether to leave the demo workers open (default)
or close the exact listed demo children. Only specific approval permits serialized
`maestro_close` calls using retained owned direct-child launch identities under
the lifecycle guide. No subtree close, other sessions, self-close, retry, removal
wait, process kill, or cleanup fallback. Preserve refusals/unknown outcomes and
name their owner/next action. Close acceptance is not removal or freed capacity.
Preserve all result/artwork files; closing is not deleting evidence.

## Presenter notes

- "These are real interactive Copilot sessions; I can continue in any surface."
- "Distinct Nerd Fonts icons and colors make the cast recognizable in icon cards."
- "Worktrees groups by repository; Sub-agents shows who spawned whom. We reuse
  a trusted launch folder read-only; all artwork lives in separate scratch space."
- "Each worker assigned its own demo and role tags; the encore tag shows steering."
- "Each invented and drew its own animated pet locally. Hover its card to see it;
  a human pet override or hidden pet can still win."
- "Process/ports hover shows only proven owned activity, not inferred work. We
  start no servers here, so an empty list is expected."
- "Launch policy is inherited without escalation; live permission changes are
  not a verified snapshot, and messaging never auto-approves tools."
- "Exact sessions can resume after a relaunch when restore is configured. We are
  describing that capability, not restarting CMUX or claiming it was tested here."
