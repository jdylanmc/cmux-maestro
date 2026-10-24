# Copilot sessions started in CMUX are born managed

A Copilot session that starts in a CMUX terminal, with the production Maestro integration installed, becomes managed when it starts. It is its own root coordinator in a new run. It gets `maestro_identity`, `maestro_peers`, `maestro_send`, `maestro_spawn`, and `maestro_close` for its own children. It peers with every participant in its workspace. There is no opt-out. A start includes `copilot --resume` of a session Maestro has not recorded. A resume of a recorded session follows re-enrollment ([ADR 0024](0024-resume-ended-managed-sessions-after-relaunch.md)).

How: Maestro's installed native extension joins every session. When CMUX workspace and surface IDs are present and no launcher inputs are, the extension asks the controller to enroll its own session. The controller checks, in order:

- The request matches the invoking session ID, CMUX workspace and surface, and the provider PID Copilot gave the extension.
- The production integration is installed.
- The provider is an ancestor of the controller with a stable start time. It started after the installed extension files were written, in a later second.
- CMUX confirms the exact workspace and surface, and `surface.list` lists the surface.
- The provider's controlling TTY equals the TTY CMUX `top` reports for that surface. Inherited `CMUX_*` values in a nested shell or multiplexer name another surface but not its TTY. Unknown refuses.
- The account comes from the session's own `gitHubAuth.getStatus()`, bounded in time. Host `github.com` or `https://github.com` is accepted and recorded as `github.com`. The node records `{login, host}`, never a credential.
- No node holds the surface, the session, or the provider process. A retained resource or launch lease on the surface also refuses.
- Node, workspace, and host capacity admit one more root.

The new root records a default launch policy unless its exact provider's launch flags
prove allow-all ([ADR 0006 amendment](0006-recorded-launch-policy-deny-wins.md)).
Its children inherit that mode and recorded denies; runtime permission toggles are not observed.

Any failed check leaves the session unmanaged. `maestro_readiness` names one stable reason, such as `capacity-unavailable` or `session-started-before-install`; `enrollment-pending` shows while enrollment runs. There is no retry and no fallback. The decision is recorded per session and provider process (session ID, PID, and start time): a later extension reload in that process returns the same refusal, or reuses the same node after an enrollment, even when the extension files changed since. Records go once the provider process is proven ended. With no recorded decision, a provider is admitted only within 120 seconds of its own start (`enrollment-window-passed` otherwise), so an unrecorded refusal cannot reopen later. Known limit: the window counts from the provider's start, so a login or trust prompt answered more than 120 seconds later leaves that session unmanaged; restart it. If the controller committed an enrollment but this extension's runtime failed, the reason is `enrolled-runtime-unavailable`. A session archived earlier and enrolled again continues its generations from a bounded per-session high-water mark that survives archive trimming, so its peer address never repeats. When the record is full, the lowest mark is evicted into one stored floor, and every later generation starts above that floor. Addresses stay unique, every proven-ended run stays archivable, and the record never blocks.

Why this is not adoption: enrollment happens when that exact session's process starts with Maestro present. Maestro never enrolls a session that was already running when the integration was installed, and never enrolls a session whose provider already belongs to another node. Live sessions are never adopted ([ADR 0004](0004-interactive-workers-only.md)).

Why: a human expects every Copilot tab in CMUX to see its peers and spawn children, and to come back after a relaunch ([ADR 0024](0024-resume-ended-managed-sessions-after-relaunch.md)). Launcher-only management left human-started tabs as diagnostic-only shells (#162).

Ended runs: a new session in a surface held by an earlier born run archives that run first, but only when the run is proven fully ended. Every node's process must be observed ended, with no launch lease, unresolved surface, or archive in progress. The archive uses the normal archive record. Children's Maestro-created surfaces stay owned as retained resources. The born root's surface was the human's, so the new root takes it. A live or uncertain run keeps the surface and the new session stays unmanaged with `surface-owned`. The human-run `archive-ended --workspace <id>` command archives every proven-ended born run in a workspace and reports the runs it kept.

Rejected: in-place enrollment of running sessions; enrollment by title, path, or focus; an opt-out (owner decision); evicting history or archiving live or uncertain runs to admit a new root ([ADR 0010](0010-history-fails-open-replay-fails-closed.md)). Superseding an ended run in its own surface is not eviction to admit: it happens whenever the surface is reused, at any capacity.

Consequence: every born session takes one stored node and one unit of workspace capacity until its run is archived. At capacity, new sessions stay unmanaged. A session started in the same second as an install, or in a surface that a live or uncertain run holds, stays unmanaged. Sessions outside CMUX, and validation builds, are untouched.

## Amendment (2026-10-18, #261): every Copilot session in CMUX is managed

Owner decision: every Copilot session in a CMUX tab, with production Maestro installed, is managed. That includes a new, resumed, relaunched or already-running session. There is still no opt-out.

- **Already running.** A session that was running when the integration was installed enrolls in place the next time Maestro's extension joins it. Copilot joins extensions only when a session starts, when its foreground session is replaced (`/clear`, `/resume`, a `--resume` startup), or when extensions are reloaded. Maestro never triggers any of these. `session-started-before-install` and the 120-second `enrollment-window-passed` refusals are removed. Enrollment only adds Maestro's tools; a live session is never controlled, signalled or restarted.
- **Persisted session.** Copilot 1.0.98 `--resume=<id>` first joins extensions to a placeholder session with a fresh ID, which it never saves, and then replaces it with the resumed session in the same process. Enrollment now requires the session's `~/.copilot/session-state/<id>` directory. A placeholder has none, so it is refused with `session-not-persisted`, records nothing, takes no surface and archives nothing. Before this, the placeholder enrolled first: it archived the resumed session's ended run in that surface, and the resumed session was refused with a misleading `provider-already-enrolled`.
- **Session custody.** Copilot writes `inuse.<PID>.lock` only at a session's first prompt. Enrollment needs that positive custody: a live marker held by the provider or its direct child, and no live marker of any other process. Before it exists, nothing is decided (`awaiting-first-prompt`, unrecorded), so two tabs resuming the same session never both look like its sole owner. The extension checks for the lock locally, at join and at later hook events (prompt submitted, session start, tool use, agent stop), and calls the controller only once it exists. Another live marker refuses with `session-live-or-uncertain`; a crashed provider's stale marker is ignored.
- **Custody while managed.** A born root acts only while its recorded provider (or that provider's direct child) is still the sole live owner of its session's lock. The controller's own anchored, bounded lock scan (512 entries) runs before every managed operation: the extension checks it through the private `native-custody` command before readiness, identity, peers, send, spawn and close, and before delivering an inbound peer message; `native-spawn` and `native-close` check it again themselves. If a second live process (another tab resuming the same session) also holds the lock, every operation refuses, readiness reports `session-custody-lost`, and nothing is recorded or changed. The loss is latched in that extension: the ambiguity ending does not restore authority. Only the next extension join re-checks custody (an extension reload re-runs it before reusing the node). Enrollment of the second tab is not relied on to revoke the first.
- **Sessions in one provider.** A born root whose own extension recorded its session's end no longer holds its provider process. The next session in that tab (after `/clear` or `/resume`) takes it over. If the earlier run is fully ended it is archived. If only its root has ended and its children still run, the root releases its surface and keeps its run and children; no row shows that run any more, its children stay observed sessions in their own tabs, and the new root has no authority over them. `archive-ended` archives the released run once every node has ended. Without a recorded end, `provider-already-enrolled` still refuses, and that reason now means exactly that another node holds this provider.
- **One decision.** Enrollments are serialized on the host, waiting at most 20 seconds (well inside the extension's 60-second call limit, which reports `enrollment-busy` if it ever fires). A decision already recorded for a session in a provider is repeated, never replaced. A reload whose node is no longer current reports `enrolled-node-unavailable`. Three refusals are not recorded: `awaiting-first-prompt`, `session-not-persisted` and `enrollment-busy`. The extension asks the controller at most twice per join; after an unrecorded refusal on the second call the reason stands until the next join.
- **Upgrade.** Refusals an earlier controller recorded and this one no longer makes (`session-started-before-install`, `enrollment-window-passed`, `session-ended`, and `provider-already-enrolled` when no node holds that provider) are decided again.
- **Plain readiness.** `maestro_readiness` adds a plain-language `message` for each reason.

The identity checks are unchanged: exact workspace, surface and terminal TTY; the session's own account; no other live custody of the session; capacity. Enrollment of a CMUX session by its own extension is not adoption.

## Amendment (2026-10-24, #348): defer incomplete enrollment evidence to session events

An unavailable account observation is not a final refusal. The session remains
unmanaged with `account-unverified`; each later exact-session prompt, start,
post-tool or agent-stop hook may observe its own account again and ask the
controller once. Previously recorded account-unverified refusals are
reconsidered, not converted to enrollments. Account mismatch and every other
definitive refusal remain final. There is no account fallback.

`provider-already-enrolled` also remains pending in the extension. A later hook
may ask again, but the controller repeats the refusal until no node holds that
exact provider. An in-process replacement still requires the earlier born
root's recorded, exact-generation session end; absent custody or extension
termination is not an end. Every admission check runs again. Concurrent events
share one attempt; no timer or daemon retries enrollment. The two-call limit
for the other unrecorded refusal reasons remains unchanged.

The extension retains at most one exact `user_exit` callback received before
its runtime observer is installed. It stores only a pending bit and forwards
the joined session's exact identity after runtime startup settles, including
failure after observer installation. It never waits for startup inside the
join callback, retains hook content, or records an end after a hangup.
The existing bounded shutdown gate is armed before join, so termination cannot
discard a buffered callback merely because the runtime has not started yet.
Definitive refusal or initialization failure settles the wait when no observer
can be installed.
An unresolved pending enrollment can therefore use the existing two-second
shutdown budget even if no observer ultimately installs. Event-driven
reconsideration also retains the existing bounded hook wait and controller
timeout costs while evidence remains incomplete. These are bounded waits, not
scheduled retries. A known definitive controller refusal takes precedence over
an unavailable account observation and stops further attempts.

This amends the earlier one-decision and retry limits only for these incomplete
observations. Deterministic synthetic controller/extension scenarios establish
the repaired ordering cases. Actual interactive `/resume` callback ordering
is still unverified; if the provider delivers no authoritative end, enrollment
continues to refuse. No existing session is probed, reloaded or controlled.
