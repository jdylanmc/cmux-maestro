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
  --cwd "$PWD" \
  --name "Coordinator"
```

Retain the returned `coordinatorId` and `controlToken` privately for this
orchestration run. `--cwd` is explicit probe provenance for the coordinator's
verified Git worktree and branch. Non-Git directories produce no Git labels;
omit it rather than guessing when the current directory is not the assigned task
root. The controller refreshes this bounded evidence during lifecycle checks.

## Spawn

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" spawn \
  --actor-id "$COORDINATOR_ID" \
  --token "$CONTROL_TOKEN" \
  --name "Focused worker name" \
  --cwd "/absolute/working/directory" \
  --task "Bounded objective, constraints, validation, and stop condition"
```

The safe default adds no Copilot tool grants. When the user explicitly approves
tools for this task, pass each exact supported Copilot rule separately:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" spawn \
  --actor-id "$COORDINATOR_ID" \
  --token "$CONTROL_TOKEN" \
  --name "Authorized implementation worker" \
  --cwd "/absolute/working/directory" \
  --task "Bounded implementation and validation" \
  --allow-tool "read" \
  --allow-tool "edit" \
  --deny-tool "web"
```

These are Copilot policy arguments, not an operating-system sandbox. Never add
`--allow-all`, a wildcard, all paths or URLs, or rights not explicitly approved
for the task. A general shell grant must also be caller-explicit and task-
justified; it is never a default. Denies win. A descendant receives no additional
grants by default and may request only a subset of its parent's explicit allows;
inherited denies cannot be removed. Policies remain private.

The command creates exactly one unfocused terminal tab beside the actor. A
foreground supervisor runs one bounded noninteractive Copilot turn with a
preassigned stable session ID, then remains in that terminal for authenticated
follow-ups. Workers may spawn descendants through the same command using their injected
`CMUX_MAESTRO_WORKER_ID` and `CMUX_MAESTRO_CONTROL_TOKEN`. Respect the depth
and eight-live-worker workspace limit; a completed report does not release a
live terminal/supervisor slot. Reuse an idle worker instead of retrying fanout
failures in a loop.

For an explicitly delegated descendant, use only the injected worker identity:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" spawn \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" \
  --token "$CMUX_MAESTRO_CONTROL_TOKEN" \
  --name "Bounded descendant" \
  --cwd "/absolute/working/directory" \
  --task "Bounded objective, constraints, validation, and stop condition"
```

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
has a verified successful exact-session boundary for its current generation.
That includes an explicitly reported blocked, completed, or failed outcome and
a bounded recovery from report-missing or permission-denied without claiming
the earlier task succeeded. The next turn keeps the existing tool policy and
uses that worker's preassigned exact `--resume` session ID. No prompt is typed
into a terminal, and there is no fallback to `--continue`, a display name, the
focused terminal, or a recent session.

## Worker reporting

The required report is permission-free. End the turn with exactly one compact
JSON object as the entire final assistant message, with no code fence, prose,
or tool request:

```json
{"protocol":"cmux-maestro.worker-report","version":1,"workerId":"<exact injected worker ID>","generation":1,"state":"completed","summary":"Brief factual result"}
```

Use the exact worker ID and generation stated in the appended turn contract.
Use `blocked` or `failed` instead of `completed` when accurate. Copilot emits
this content in an envelope shaped as
`{"type":"assistant.message","data":{"phase":"final_answer","toolRequests":[],"content":"..."}}`;
do not call a tool to submit it. The supervisor requires that exact phase,
empty tool requests, exact report fields and identity, and the successful
current-session process/result boundary. A normal answer or zero exit is not
task success.

The authenticated `report` subcommand remains an optional compatibility path
when an already-approved caller can execute it. Do not rely on that path:
noninteractive Copilot may deny a tool without offering the human a prompt.
Dual final-message and helper reports are refused rather than reconciled.
Reports are self-reported operational evidence, not independent review or
artifact acceptance. Keep secrets, raw output and full prompts out of summaries.

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
  --cwd "$PWD" \
  --name "Coordinator"
```

Recovery never guesses from a title, directory, focused tab, or recent session.
