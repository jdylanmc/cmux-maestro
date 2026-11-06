# Born managed sessions (#252, ADR 0025)

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Installed lifecycle and permissions](installed-lifecycle.md) | [Ordinary-session readiness (partial #162) →](ordinary-session-readiness.md)

A Copilot session in a CMUX terminal with no launcher inputs enrolls itself as
its own root coordinator when the loader joins it: at its start, at a resume,
or, for a session already running, at its next extension join (#261). The loader joins once with the
managed tools plus `maestro_readiness`. The managed tools refuse until
enrollment succeeds. The loader then reads the session's own account with
`gitHubAuth.getStatus()` and calls the controller's private `native-enroll`
ingress with the session, workspace, surface, provider PID
(`COPILOT_EXTENSION_PARENT_PID`) and account. The controller verifies each value
and either records a new root and publishes its route, or refuses with one
stable reason. `maestro_readiness` then reports `managed` with the node and
generation, or `diagnostic-only` with that reason. See
[ADR 0025](../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md) for
the checks.

Reasons: `enrollment-pending`, `enrolled-runtime-unavailable`, `enrolled-node-unavailable`,
`provider-process-unverified`, `account-unverified`, `integration-not-installed`,
`awaiting-first-prompt`, `session-not-persisted`, `enrollment-busy`, `cmux-identity-unverified`, `surface-owned`,
`provider-already-enrolled`, `session-previously-managed`, `capacity-unavailable`,
`session-live-or-uncertain`, `enrollment-failed`.
A resumed session also uses `surface-mismatch`, `account-mismatch` (with the
recorded login) and `account-unrecorded`. See
[Relaunch restore](../reference/relaunch-restore.md).
Readiness adds a plain-language `message` for each reason.
The loader calls the controller only once Copilot holds the session: its
`inuse.<PID>.lock` exists, which happens at the first prompt. Until then readiness
reports `awaiting-first-prompt`. The `onUserPromptSubmitted`, `onSessionStart`,
`onPostToolUse` and `onAgentStop` hooks re-check only for the exact joined session,
without reading their content.
`awaiting-first-prompt`, `session-not-persisted` (Copilot's never-saved `--resume`
startup placeholder) and `enrollment-busy` are not recorded; the loader asks the
controller again after the first such refusal; the second is final for the
join, even when the reasons differ. Account/provider deferrals neither consume
nor reset this shared budget. `account-unverified` stays
pending and unrecorded. Later exact-session hooks observe the account again.
Previously recorded account-unverified refusals are reconsidered. A provider
conflict stays pending too, but its recorded refusal permits enrollment only
after no node holds that exact provider. Missing custody never releases a node.
Each later event permits one attempt, and concurrent events share it. There is no
timer-driven enrollment or account fallback. Other decisions are recorded per
session and Copilot process and repeated on reload. Enrollments are serialized on the host
(20-second wait, inside the loader's 60-second call limit).
While managed, the loader asks the controller's private `native-custody` command
before readiness, identity, peers, send, spawn, close and each inbound peer
message. The controller re-checks spawn and close itself. A second live holder of
the session latches `session-custody-lost` until the next join.
Unknown controller output becomes `enrollment-failed`. Raw errors are never shown.
One exact user-exit callback can be buffered during join until the managed
observer is installed and runtime startup settles. Only a pending bit is held;
the controller receives the original node/session/generation identity, never
hook content. Hangup and forged-session checks remain in place. Actual CLI
callback ordering during interactive `/resume` remains unverified (#348).

The [readiness-only branch](ordinary-session-readiness.md) now applies only when launcher inputs are
incomplete.
