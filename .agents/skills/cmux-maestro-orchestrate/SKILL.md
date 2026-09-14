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

The command creates exactly one unfocused terminal tab beside the actor and
starts one interactive Copilot session with a preassigned stable session ID.
Workers may spawn descendants through the same command using their injected
`CMUX_MAESTRO_WORKER_ID` and `CMUX_MAESTRO_CONTROL_TOKEN`. Respect the depth
and active-child limits; do not retry fanout failures in a loop.

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

Follow-up is allowed only for a directly owned worker that explicitly reported
blocked, completed, or failed for its current generation and whose exact
Copilot process and CMUX surface still validate. There is no fallback to
`--continue`, a display name, the focused terminal, or a recent session.

## Worker reporting

Before becoming idle after every turn, report exactly once:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" report \
  --generation "$CURRENT_GENERATION" \
  --state completed \
  --summary "Brief factual result"
```

Use `running`, `blocked`, or `failed` when accurate. A terminal's existence, a
normal assistant response, or a zero process exit is not task success. Reports
are operational evidence, not independent review or acceptance. Do not place
secrets, raw output, or full task prompts in summaries.
