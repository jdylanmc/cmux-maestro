# Copilot sessions started in CMUX are born managed

A Copilot session that starts in a CMUX terminal, with the production Maestro integration installed, becomes managed when it starts. It is its own root coordinator in a new run. It gets `maestro_identity`, `maestro_peers`, `maestro_send`, `maestro_spawn`, and `maestro_close` for its own children. It peers with every participant in its workspace. There is no opt-out. A start includes `copilot --resume`.

How: Maestro's installed native extension joins every session. When CMUX workspace and surface IDs are present and no launcher inputs are, the extension asks the controller to enroll its own session. The controller checks, in order:

- The request matches the invoking session ID, CMUX workspace and surface, and the provider PID Copilot gave the extension.
- The production integration is installed.
- The provider is an ancestor of the controller with a stable start time. It started after the installed extension files were written, in a later second.
- CMUX confirms the exact workspace and surface, and `surface.list` lists the surface.
- The account comes from the session's own `gitHubAuth.getStatus()`. Only `github.com` is accepted. The node records `{login, host}`, never a credential.
- No node holds the surface, the session, or the provider process. A retained resource or launch lease on the surface also refuses.
- Node, workspace, and host capacity admit one more root.

The new root records a default launch policy with no grants and no YOLO ([ADR 0006](0006-recorded-launch-policy-deny-wins.md)). Its children inherit that policy.

Any failed check leaves the session unmanaged. `maestro_readiness` names one stable reason, such as `capacity-unavailable` or `session-started-before-install`. There is no retry and no fallback. An extension reload in the same enrolled provider process reuses the same node.

Why this is not adoption: enrollment happens when that exact session's process starts with Maestro present. Maestro never enrolls a session that was already running when the integration was installed, and never enrolls a session whose provider already belongs to another node. Live sessions are never adopted ([ADR 0004](0004-interactive-workers-only.md)).

Why: a human expects every Copilot tab in CMUX to see its peers and spawn children, and to come back after a relaunch ([ADR 0024](0024-resume-ended-managed-sessions-after-relaunch.md)). Launcher-only management left human-started tabs as diagnostic-only shells (#162).

Ended runs: a new session in a surface held by an earlier born run archives that run first, but only when the run is proven fully ended. Every node's process must be observed ended, with no launch lease, unresolved surface, or archive in progress. The archive uses the normal archive record. Children's Maestro-created surfaces stay owned as retained resources. The born root's surface was the human's, so the new root takes it. A live or uncertain run keeps the surface and the new session stays unmanaged with `surface-owned`. The human-run `archive-ended --workspace <id>` command archives every proven-ended born run in a workspace and reports the runs it kept.

Rejected: in-place enrollment of running sessions; enrollment by title, path, or focus; an opt-out (owner decision); evicting history or archiving live or uncertain runs to admit a new root ([ADR 0010](0010-history-fails-open-replay-fails-closed.md)). Superseding an ended run in its own surface is not eviction to admit: it happens whenever the surface is reused, at any capacity.

Consequence: every born session takes one stored node and one unit of workspace capacity until its run is archived. At capacity, new sessions stay unmanaged. A session started in the same second as an install, or in a surface that a live or uncertain run holds, stays unmanaged. Sessions outside CMUX, and validation builds, are untouched.
