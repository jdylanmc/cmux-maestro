# Resume ended managed sessions after relaunch

After CMUX quits or crashes and opens again, a managed session may come back in its restored surface on its exact session. Each node has exactly one restore owner, chosen by how the session started:

| Session | Restore owner | How |
|---|---|---|
| Maestro launch (`maestro_spawn` child or `launch-coordinator` root) | Maestro resume binding | `<controller> resume <session-id>` starts `copilot --resume=<id>` |
| Human-started root (born managed) | CMUX's own Copilot restore | Maestro re-enrolls the resumed session ([ADR 0025](0025-copilot-sessions-started-in-cmux-are-born-managed.md)) |

## Maestro-launched sessions: resume binding

- **Single owner.** The launch sets `CMUX_COPILOT_HOOKS_DISABLED=1`, so CMUX's own Copilot restore never records or claims the tab. CMUX runs its own restore before custom bindings; without this, two processes could resume one session.
- **Identifiers only.** The binding's argv is the stable installed controller path, `resume`, and the session ID; CMUX keeps the workspace, surface and working directory as the binding's metadata. No environment is set. No token, prompt, or temporary-file path. Credentials are resolved privately only after every check passes, go into the provider's process environment only, and are never persisted, printed, or passed through CMUX.
- **Human-approved prefix.** CMUX runs the binding only after a human approves its command prefix. Maestro never approves it. The binding is `<controller> resume <session-id>`: the session ID is its only varying, trailing argument, so CMUX can approve the prefix `<controller> resume` once for every Maestro launch. The node is found by that unique session ID and every identity check runs again inside the lock.
- **This terminal.** The resume runs only as the restored surface's own terminal process: its controlling TTY must be the one CMUX reports for that surface, checked before any credential is read and again right before Copilot starts.
- **Eligible only after a relaunch loss.** The binding survives a CMUX quit, crash, or machine restart. A Copilot `SessionEnd` for that exact session's `/exit` clears it. Copilot reports `user_exit` for a quit, hangup, or signal too, so a `SessionEnd` after the extension sees `SIGHUP` is never trusted. A closed tab takes its binding with it. Archive removes the node, so the binding refuses. Missing or unclear evidence refuses.
- **Maestro observes its own SessionEnd.** Maestro's native extension, joined to each Maestro launch, is the SessionEnd observer for binding nodes. `CMUX_COPILOT_HOOKS_DISABLED` silences only CMUX's hooks; the SessionEnd observer honors only Maestro's own `MAESTRO_NATIVE_DISABLED`, and so does Maestro's identity hook. The binding refuses when the Maestro integration that carries this observer is not installed.
- **Ended session only.** No live or uncertain process holds the session: the recorded process is observed ended, and no live `inuse.<PID>.lock` owner exists.
- **Exact identity.** The terminal's CMUX workspace and surface, the node, and the session ID all match the record. Never by title, path, focus, chronology, or terminal text.
- **Recorded account or refuse.** The node's recorded account must resolve. Otherwise refuse and name the account. Never fall back to another account.
- **Recorded policy, deny wins.** The recorded model, allow rules, deny rules, and mode are replayed as recorded. No new grants, no YOLO escalation ([ADR 0006](0006-recorded-launch-policy-deny-wins.md)).
- **`--resume=<id>` with no `--name`.** Copilot rejects `--name` with `--resume`; the session keeps its name. No new session ID or prompt.
- **New generation.** Each resume records the next generation of the same node, with a new control token and peer route. Prior history stays. Depth, node, capacity, and retained-resource bounds still apply.
- **Plain shell on refusal.** Any refusal prints one diagnostic line and leaves the restored shell. No retry, no fallback to an unmanaged resume, no keystrokes.

## Human-started roots: re-enrollment

CMUX has already started `copilot --resume <id>` before Maestro sees the tab, so the account, policy, and plain-shell rules above cannot apply. Re-enrollment instead requires: the exact recorded session, workspace, and surface; the prior process observed ended; the new provider as the only live lock owner; the recorded account equal to the session's own reported account; and no observed `/exit` of that generation. Maestro's extension records a `SessionEnd` only for `/exit`: Copilot reports `user_exit` for a quit, hangup, or signal too, and only those send the extension `SIGHUP` first, so a session end after `SIGHUP` is never recorded. A manual resume after a recorded `/exit` is the human's new start and refuses. It records the next generation of the same node. Any mismatch leaves the session running but unmanaged, with one `maestro_readiness` reason; an account mismatch names the recorded account. Details: [ADR 0025](0025-copilot-sessions-started-in-cmux-are-born-managed.md).

Why: CMUX ended the process, not the human or Maestro. Resuming the exact session rebuilds work the human already authorized. It does not adopt live work. Without it, relaunch turns managed agents into unmanaged shells (#162).

Relationship: amends [ADR 0004](0004-interactive-workers-only.md) (a fresh session ID is for new workers only). [ADR 0002](0002-exact-identity-evidence-never-heuristics.md): exact identity only. [ADR 0003](0003-liveness-work-attention-completion-stay-separate.md): a resume says nothing about task success. [ADR 0006](0006-recorded-launch-policy-deny-wins.md): recorded policy, deny wins.

Rejected: CMUX's own Copilot restore for Maestro launches (drops launch flags, account, and parent link; fails with `--name`); two restore owners for one node; automatic prefix approval; keystroke or paste replay; adopting on-disk sessions; resuming a live or uncertain session; credentials or temporary paths in a binding, its environment, or files; account fallback.

Consequence: Maestro launches need one human approval of the prefix `<controller> resume` in CMUX (a prompt-time approval may be scoped to one folder; approving the prefix in CMUX's Resume Commands settings covers every launch). Node history gains one generation per resume. A launched node's recorded account is its pinned launch login, so older launched nodes resume too. Any mismatch leaves a plain shell (binding) or an unmanaged session (re-enrollment), plus one diagnostic. There is no opt-out (owner decision).
