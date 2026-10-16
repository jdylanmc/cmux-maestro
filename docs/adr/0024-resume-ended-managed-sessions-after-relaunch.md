# Resume ended managed sessions after relaunch

After CMUX quits or crashes and reopens, Maestro may resume an ended managed session in its restored terminal. The restore mechanism is a separate implementation choice. Every mechanism must keep these invariants:

- **Ended session only.** No live or uncertain process holds the session. A live `inuse.<PID>.lock` owner, or a recorded process that may still run, refuses. Two processes on one session can corrupt its state.
- **Exact identity.** The recorded session ID, workspace UUID, and surface UUID must match exactly. Never select a session by title, path, focus, chronology, or terminal text.
- **New generation.** Each resume records a new generation for the same node. Prior history stays. Depth, node, capacity, and retained-resource bounds still apply.
- **Recorded account or refuse.** Resume uses the node's recorded account `{login, host}`. If that account is not available, refuse and name the account in the diagnostic. Never fall back to another account. Credentials stay out of argv, prompts, logs, and files.
- **Recorded policy, deny wins.** Resume replays the recorded launch policy. No new grants, no YOLO escalation ([ADR 0006](0006-recorded-launch-policy-deny-wins.md)).
- **No keystrokes.** Never type or paste into a terminal to resume, retry, or recover.

Any refusal leaves a plain shell and one clear diagnostic. No retries and no fallback to an unmanaged resume.

Why: CMUX ended the process, not the human or Maestro. Resuming the exact session rebuilds work the human already authorized. It does not adopt live work. Without it, relaunch turns managed agents into unmanaged shells (#162).

Relationship: amends [ADR 0004](0004-interactive-workers-only.md) (a fresh session ID is for new workers only). [ADR 0002](0002-exact-identity-evidence-never-heuristics.md): exact identity only. [ADR 0003](0003-liveness-work-attention-completion-stay-separate.md): a resume says nothing about task success. [ADR 0006](0006-recorded-launch-policy-deny-wins.md): recorded policy, deny wins.

Rejected: keystroke or paste replay; adopting on-disk sessions; resuming a live or uncertain session; credentials in argv or files; account fallback.

Consequence: node history gains one generation per resume. Nodes recorded before account recording have no recorded account and cannot be resumed as managed. Any mismatch leaves a plain shell plus a diagnostic.
