# Sidebar rows

[↑ Relaunch restore](../relaunch-restore.md) | [← One-time approval in CMUX](one-time-approval-in-cmux.md) | [Known gaps →](known-gaps.md)

The sidebar shows an unmanaged Copilot row only after Maestro's observer hook binds the session to its surface. A restored session can show the CMUX surface title until that binding exists. Live checks must confirm when the hook binds a resumed session.

A born-managed or resumed managed session is expected not to wait for the hook: the controller's projection names its exact surface, so the sidebar should show a managed Copilot row as soon as the projection is read. This is not yet confirmed in a live CMUX (see [Live checks](live-checks.md)). A born root's row shows its Copilot session name under ADR 0022's rules: one live, fresh observation of that exact session in that workspace and surface, or the last name read during observation loss while its grace lasts.

Copilot 1.0.98 defers a resumed session's `sessionStart` hook and its `inuse.<PID>.lock` until the first prompt, so the observer hook cannot bind a relaunched session before then. Until the observer has any evidence of that session, a running born root's row takes its name, and its pet, from the exact session UUID in the controller's projection (ADR 0022 amendment, #261). Otherwise it shows `Copilot session`.

[Earlier behavior](../../evidence/reference.md#sidebar-rows).
