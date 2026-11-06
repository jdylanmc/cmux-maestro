# Bounded live checks and cleanup

Part of the [native delivery proof](../delivery-proof.md). Previous page is [Parent-only preparation and live launch](live-launch.md). Next page is [Parent-reported installed exchange and skill-name correction](installed-exchange.md).

## Bounded live checks

After both adapters load, the human asks A to send one synthetic message,
for example: `Ask the other proof peer for the word "violet"; request one reply
to your return address.` Observe the ordinary reply in A, without adding protocol
acknowledgements or waiting logic. Limit each observation to 120 seconds; missing
output is an inconclusive/failed observation, not a reason to resend automatically.

Repeat separate, explicitly requested single sends while:

1. B is selected and its input is focused.
2. The human is typing or has an unsent sentinel draft in B. Check the exact draft
   and editability before/after. This check requires human participation.
3. Another workspace is selected, then CMUX is app-backgrounded.
4. B has active work; let Copilot choose scheduling, without asserting when it
   must run the new prompt.
5. The sidebar is hidden.

Observe no focus stealing, workspace switching, draft clearing/submission, or
keystroke interference. Record versions, synthetic bodies, sanitized workspace/
session aliases, visible observations, and unmet cases. Do not copy binding
files, controller state, credentials, raw provider logs, or unrelated transcripts.
No mocks prove these checks. Stop on interference.

## Local validation and cleanup

```sh
python3 scripts/test-delivery-proof.py
node --test scripts/test-delivery-proof.mjs
python3 scripts/test-cmux-maestro-orchestrator.py
```

The first two suites use disposable files and local sockets under `.build/`,
with mocked native sessions/launcher processes, and remove their own fixtures.
No dependencies are added. Repository CI's other declared checks remain
unchanged and belong to the parent’s complete validation pass.

The orchestrator suite uses fake CMUX/Copilot processes in temporary roots.
Its fixture-only Python startup hook carries a shared lifetime descriptor
through subprocesses and shell execution. Teardown closes fixture admission,
signals only recorded PID/start identities, and requires exclusive lifetime
ownership before deleting the root. A writer that outlives the existing
three-second shutdown budget causes an explicit failure and preserves the
sandbox, including against automatic temporary-directory cleanup. Do not remove
a preserved root until its exact fixture processes have stopped. New fixture
launch paths must preserve the lifetime descriptor and startup hook; neither
is installed into real CMUX or Copilot sessions.

Parent validation before the permission correction: **all 9 declared repository
CI command steps passed on first attempts**, including **45/45** orchestrator
tests and **7 Python + 7 Node** proof tests. The earlier worker-only 44/45 result
came from forcing `TMPDIR` inside this Git worktree, not the normal parent run.
The permission correction adds targeted Python coverage for default/opt-in
launches, preserved denies/pins, serialized opt-in, refusal outside proof, and
old stored-node compatibility. Full post-correction CI belongs to the parent.
Post-correction targeted validation: **12/12 Python proof tests passed**, and
`git diff --check` passed. No live endpoints were operated or reloaded.

After the human stops the two exact proof sessions, use existing owned-worker
archive/recovery guidance as applicable. The adapter does not kill providers,
close tabs, or delete controller records. Only then remove the exact disposable
`$PROOF` directory. Never delete it while extensions are live, reuse its bindings,
or clean other runs. Preserve sanitized human findings alongside this prototype
before recommending anything for #38. Current recommendation: **core mechanism
demonstrated**, including fresh explicit YOLO launches and the bounded
[app-background observation](../evidence/delivery-proof.md#l3-app-background-delivery-observation);
complete sidebar-hidden verification before
claiming that condition.
