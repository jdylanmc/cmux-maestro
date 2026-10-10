# Issue #112 working HTML reference

This runnable copy is derived from the frozen September 29 reference ZIP
(`sidebar-refinement-target-20260929.zip`, SHA-256
`4b54c765a550f3081fc88ccd57a6cbfa701d83bb59ee8e868ec122f3b5d8093a`).
The archived ZIP, its manifest, review gallery, capture hashes, and approval
remain unchanged. This copy only corrects the demonstrated S53-S55 reference
transitions; it is not a new visual approval or proof of native behavior.

Run `python3 prototype/serve.py` from this directory, then from `prototype/`:

```sh
npm ci
npm run test:copy
npm run test:issue-112
npm run test:stress
```

The copy suite retains the archived raw-value, reveal, clipboard-isolation,
error/retry, keyboard, and viewport assertions. `verify-issue-112.cjs` adds
subject-scroll, delayed pointer dismissal, and preview-origin dialog return
checks tied to S53-S55. All browser clipboard writes use an in-page stub; the
reference remains synthetic and performs no host/session operation.

Only the copy, stress, and issue-specific runners are duplicated into this
working folder. The other September 29 verification scripts remain unchanged
inside the frozen ZIP.

## Updates reconciled with the native sidebar (October 10)

This working copy was updated to match the shipped native sidebar; it is still
synthetic and not a new visual approval:

- The header has five actions: directory-plus, Beats, Taskboard, History and
  Maestro settings. The Fermata (Keep Mac Awake) control was removed because CMUX
  exposes no such control to sidebar extensions.
- A pending question is a slowly pulsing light-blue question mark with a matching
  row tint (no spinner, error color or "Waiting for answer" line). Finished work
  and turn-finished show a checkmark instead of a text line.
- Pets: the default is the original bundled Maestro robot head; the picker adds
  simulated **Upload pet…** and **Save to my pets** (an agent-made pet is
  session-only until saved), a gallery link, and **Reset to agent's pet**. The
  other three pets remain original geometric placeholders.
