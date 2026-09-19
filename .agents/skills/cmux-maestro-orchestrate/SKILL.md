---
name: cmux-maestro-orchestrate
description: Launch chat-ready interactive Copilot workers in CMUX terminal tabs with explicit ownership and bounded permissions. Humans can continue the conversation directly in each worker tab.
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

## Require the dedicated Maestro launch settings

Before the first spawn, verify the installed controller supports and reports the
private Agent launch settings:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" launch-settings
```

Proceed only when the response has `ok: true`, `accountPinned: true`,
`modelPinned: true`, `accountAvailable: true`, and `ready: true`. The response
intentionally reveals neither the account name nor the model. If the command is
unavailable, any field is false, or the settings are unreadable, stop before
creating a worker and direct the human to the installed CMUX Maestro app's
**Agent launch settings**. Never substitute the coordinator's account, active
GitHub CLI account, ambient token, Copilot default, or a hardcoded model.

The controller resolves the selected account credential only at launch, passes
it privately through `COPILOT_GITHUB_TOKEN`, and supplies the configured model.
An unavailable account fails closed before a terminal is created. Do not add
account or model arguments to the skill command.

## Spawn

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" spawn \
  --actor-id "$COORDINATOR_ID" \
  --token "$CONTROL_TOKEN" \
  --name "Focused worker name" \
  --cwd "/absolute/working/directory" \
  --require-pinned-launch-settings \
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
  --require-pinned-launch-settings \
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

The command creates exactly one unfocused terminal tab beside the actor and
launches normal interactive Copilot with the supplied initial task. The account
and model come only from the verified local **Agent launch settings**. This
skill always requires both settings and never falls back to normal Copilot
defaults. No personal account or model is shipped as a project default. Input and
output belong directly to that terminal: the human can type follow-ups, answer
questions, and continue after the first task finishes. A foreground supervisor
maintains ownership and metadata without intercepting terminal input. Launch
uses a private one-time credential, never a token typed into shell history.

Do not create headless-worker tabs. For explicitly requested background work,
prefer the provider's normal tabless subagent facilities; this skill does not
offer a new headless launch mode.

Workers may spawn descendants through the same command using their injected
`CMUX_MAESTRO_WORKER_ID` and `CMUX_MAESTRO_CONTROL_TOKEN`. Respect the depth
and eight-live-worker workspace limit; finishing an initial task does not release
an open interactive session or terminal slot. Reuse an idle worker instead of retrying fanout
failures in a loop.

For an explicitly delegated descendant, use only the injected worker identity:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" spawn \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" \
  --token "$CMUX_MAESTRO_CONTROL_TOKEN" \
  --name "Bounded descendant" \
  --cwd "/absolute/working/directory" \
  --require-pinned-launch-settings \
  --task "Bounded objective, constraints, validation, and stop condition"
```

## Inspect and focus

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" status \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN"

"$CMUX_MAESTRO_ORCHESTRATOR" focus \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --worker-id "$WORKER_ID"
```

Humans send follow-ups directly in the worker's Copilot interface. Programmatic
follow-up is refused for interactive workers pending workspace messaging (#38).
Never use `send`, `send-key`, pasted prompts, or terminal keystrokes to work
around this boundary; a human may be using the same input.

For existing legacy bounded workers only, `follow-up` remains privately queued
and allowed only for a directly owned worker that
has a verified successful exact-session boundary for its current generation.
That includes an explicitly reported blocked, completed, or failed outcome and
a bounded recovery from report-missing or permission-denied without claiming
the earlier task succeeded. The next turn keeps the existing tool policy and
uses that worker's preassigned exact `--resume` session ID. No prompt is typed
into a terminal, and there is no fallback to `--continue`, a display name, the
focused terminal, or a recent session.

## Interactive completion and legacy reporting

Interactive workers converse normally. Do not append a machine-report contract
or turn their final answer into lifecycle JSON. Their observed working, idle,
blocked and ended states come from validated session evidence. An interactive
process exit is not proof that its task succeeded.

Only an existing legacy bounded worker whose injected execution mode is
`bounded` uses the following compatibility protocol. Its report is permission-free.
End the turn with exactly one compact
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

Close interactive sessions normally before archiving; archive refuses while an
interactive session or its supervisor is live. Existing sessions are never
automatically converted, restarted or closed by an update.

For legacy bounded workers, archive asks idle supervisors to exit but never kills a process or deletes a
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
