---
name: maestro-pet
description: Make, add and choose a Codex-compatible pet for your own Copilot session in Maestro. Wraps the hatch-pet skill for creation, validates the spritesheet, and selects it for this session only until the human saves it for reuse.
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

## Make a new pet (wraps hatch-pet)

A valid Codex pet is a folder with `pet.json` and a transparent PNG or WebP
spritesheet of exactly **1536x1872** pixels: 8 columns x 9 rows of 192x208 cells. Rows
in order: idle, running-right, running-left, waving, jumping, failed, waiting, running,
review. Maestro shows `idle`, `running` (working), `waiting` (needs input), `waving`
(turn finished) and `failed` (blocked or failed).

1. If the human already has a pet folder, use it; skip to "Add and choose".
2. Otherwise use the **hatch-pet** skill to create one. If it is not installed, tell the
   human to install it (`npx skills add openai/skills --skill hatch-pet`) rather than
   installing skills yourself. Let hatch-pet drive image generation, QA and packaging;
   do not call image APIs directly or hand-draw a spritesheet.
3. hatch-pet packages the finished pet under `${CODEX_HOME:-$HOME/.codex}/pets/<id>/`.
   Original artwork only: do not copy proprietary or third-party character art unless
   the human supplied it and has the right to use it.

## Add and choose

```sh
# add a pet folder (or a bare spritesheet image) and choose it for this session
"$MAESTRO" pet --self --session-id "$SESSION" --add "$HOME/.codex/pets/<id>"

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
