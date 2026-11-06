# Launch commands and interactive workers

Part of [Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md). Previous page is [Sidebar layout](sidebar-layout.md). Next page is [Explicit close](explicit-close.md).

Installed skill exposes `launch-coordinator`, `launch-settings`, `status`,
`focus`, and `archive`. `register` and exact stale-surface `recover` remain for
legacy lifecycle ownership. Registration is not messaging adoption.
Start new managed coordinator with explicitly selected initial account and
model. Public `maestro_identity` tool reports actual session/account
without credentials. Native `maestro_spawn` reads that session's current account
for each child. It keeps explicit model selection and permission bounds.
Saved account defaults and unrelated Git authentication never select child's
subscription. Missing identity/API/credentials fail before terminal creation.
Current credential resolver uses GitHub CLI's keychain-backed account
store. Authenticate required account there once. Copilot-only login is
not silently imported or replaced with another GitHub CLI account.
A managed node's **recorded account** `{login, host}` is its launch's pinned
GitHub.com login, or, for a session that reported its own account, that
observed account. One store only, and it holds no credential. Older launched nodes
derive it from their launch settings. A resume after relaunch must use it or
refuse ([ADR 0024](../../adr/0024-resume-ended-managed-sessions-after-relaunch.md)).
A session the human starts in CMUX is **born managed** as its own root
([ADR 0025](../../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md)).
Its node has `enrollment: "born"`, generation 1, the label `Copilot session`,
the account its own session reports, and a default policy with no grants.
It has no control token: it acts only through its native tools. Its children
use the normal `maestro_spawn` path.
A new session in a surface held by a **proven-ended** born run archives that
run first. Children's surfaces become retained resources; the root's surface
goes to the new root. To free capacity by hand, run
`cmux-maestro-orchestrator archive-ended --workspace <id>`. It archives only
proven-ended born runs and reports `archivedRuns`, `keptRuns`, and capacity.
Direct launches set `CMUX_COPILOT_HOOKS_DISABLED=1` and attach a CMUX resume
binding to their surface. After a relaunch, `cmux-maestro-orchestrator resume <session>` resumes them as
the next generation. See [Relaunch restore](../relaunch-restore.md).
Ordinary shell `spawn` cannot establish that evidence and refuses. Source-only
disposable proof compatibility is not production fallback. **New workers are
interactive Copilot sessions**, launched with `--interactive` and initial
task. Their terminal is a normal conversation where humans can type follow-ups and
answer permission/questions directly. Completing task does not close it.
Copilot itself owns terminal I/O, including Ctrl-C. Maestro adds no interactive
supervisor or captured JSON stream. Observed process exit never claims task
success. New workers cannot be
launched in headless mode. Never substitute invisible SDK tasks for
visible Maestro roles when startup fails.
