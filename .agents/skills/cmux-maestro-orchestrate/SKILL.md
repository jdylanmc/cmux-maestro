---
name: cmux-maestro-orchestrate
description: Spawn and coordinate bounded Copilot workers in background CMUX terminal tabs with explicit ownership and lifecycle reporting.
---

# CMUX Maestro Orchestration

Use this skill only when the user explicitly delegates work to another Copilot
session. Each worker receives a real terminal tab in the coordinator's current
CMUX pane and workspace. Never create a window or split.

Set the command path once:

```sh
CMUX_MAESTRO_ORCHESTRATOR="${CMUX_MAESTRO_ORCHESTRATOR:-$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator}"
```

## Register the current coordinator

Use only the exact CMUX environment identities. Never infer a surface from a
title, directory, screen contents, or current focus:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" register \
  --workspace "$CMUX_WORKSPACE_ID" \
  --surface "$CMUX_SURFACE_ID" \
  --name "Coordinator"
```

Retain the returned `coordinatorId` and `controlToken` privately for this
orchestration run.

## Spawn

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" spawn \
  --actor-id "$COORDINATOR_ID" \
  --token "$CONTROL_TOKEN" \
  --name "Focused worker name" \
  --cwd "/absolute/working/directory" \
  --task "Bounded objective, constraints, validation, and stop condition"
```

The command creates exactly one unfocused terminal tab beside the actor. A
foreground supervisor runs one bounded noninteractive Copilot turn with a
preassigned stable session ID, then remains in that terminal for authenticated
follow-ups. Workers may spawn descendants through the same command using their injected
`CMUX_MAESTRO_WORKER_ID` and `CMUX_MAESTRO_CONTROL_TOKEN`. Respect the depth
and eight-live-worker workspace limit; a completed report does not release a
live terminal/supervisor slot. Reuse an idle worker instead of retrying fanout
failures in a loop.

## Inspect, follow up, and focus

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" status \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN"

"$CMUX_MAESTRO_ORCHESTRATOR" follow-up \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --worker-id "$WORKER_ID" --task "One bounded follow-up"

"$CMUX_MAESTRO_ORCHESTRATOR" focus \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --worker-id "$WORKER_ID"
```

Follow-up is queued privately and allowed only for a directly owned worker that
explicitly reported blocked, completed, or failed and whose supervisor has
verified the exact current turn boundary. The next turn uses that worker's
preassigned exact `--resume` session ID. No prompt is typed into a terminal,
and there is no fallback to `--continue`, a display name, the focused terminal,
or a recent session.

## Worker reporting

Before becoming idle after every turn, report exactly once:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" report \
  --generation "$CURRENT_GENERATION" \
  --state completed \
  --summary "Brief factual result"
```

Use `blocked` or `failed` instead of `completed` when accurate. The report stays
pending until the foreground supervisor verifies that generation's Copilot
process/result boundary. A terminal's existence, a
normal assistant response, or a zero process exit is not task success. Reports
are operational evidence, not independent review or acceptance. Do not place
secrets, raw output, or full task prompts in summaries.

## End or recover a run

Archive an owned run before reusing its coordinator surface:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" archive \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN"
```

Archive asks idle supervisors to exit but never kills a process or deletes a
terminal. Still-present worker terminals remain counted as retained resources.
If the coordinator token is lost, `recover` may issue a new run only after the
exact current caller workspace/surface matches, ownership is stale, and no
worker process or surface from that run remains:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" recover \
  --workspace "$CMUX_WORKSPACE_ID" \
  --surface "$CMUX_SURFACE_ID" \
  --name "Coordinator"
```

Recovery never guesses from a title, directory, focused tab, or recent session.
