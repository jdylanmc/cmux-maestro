# Parent-owned installed-product verification

[↑ Native delivery proof](../delivery-proof.md) | [← Installed adapter wiring](installed-adapter.md)

No installed replacement or provider launch was performed by the implementation
worker. After full CI/review and explicit setup approval:

1. Build/package the normal app; use only its existing explicit production setup
   action. The validation copy must still refuse installation. Confirm the app
   bundle contains `adapter.mjs`, `extension.mjs`, and the lifecycle/icon skills,
   but no bundled messaging guide; inspect
   only sanitized `launch-settings` (`ready` and `messagingInstalled`), not secrets.
   Open **Settings > CLI Integration** and verify the displayed command and copy
   affordance. Before merge, use the local-source command in
   [guide distribution](guide-distribution.md) only with explicit
   consent to refresh the user's already-working global copy; do not use an
   unpublished GitHub source as an acceptance proxy.
2. In a fresh disposable workspace, use existing lifecycle registration/spawn
   guidance and an ordinary working directory. Do **not** run fixture preparation
   or set test-mode overrides to claim installed behavior. Launch three fresh
   participants; permit default native trust/tool prompts normally, or use
   coordinator `--yolo` only when explicitly approved.
3. Verify global `/maestro` / `{"skill":"maestro"}` discovery after any consentful
   refresh, and that `maestro_peers` returns the other two
   participants, not an unmanaged terminal, old proof session, or other workspace.
   Ask one participant for one ordinary send/reply through `maestro_send`.
   Verify exact-generation return addresses and no implicit lifecycle authority.
4. Reuse the [bounded live checks](live-checks.md), keeping draft preservation, app-background
   and sidebar-hidden observations separate. Historical live proof demonstrates
   the mechanism, **not** installation or new multi-peer acceptance. Sidebar-hidden
   remains unverified until explicitly observed.
5. Close only these new sessions normally. Verify their routes disappear and
   unavailable recipients do not cause retries or focus/input changes. Never
   touch the four preserved proof sessions or the existing human draft.

For safe **offline isolated acceptance now**, rerun the setup contract test and
adapter suites in this worktree. They exercise private disposable `.build/` paths,
the installer file writer, exact tool registration and native submission contracts
with mocked sessions, and clean only their own fixtures. The unsigned bundle can
be inspected without opening or installing it. Do not bypass its production
mutation guard to claim a live installed test. Live acceptance is a separate
parent-authorized action using fresh sessions, not an excuse to reuse or reload
the preserved proof routes.

Contract tests cover the generalized adapter, inert outside-CMUX/mismatched loader,
nonprivileged ordinary-session readiness, three-peer
send/reply, foreign workspaces, stale generations, revoked participation, strict
invocations, bound payloads, installer resources and preserved live routes,
coordinator-only YOLO, inherited route scrubbing, pinned launches and legacy
proof/state compatibility. These tests are registered in the existing CI command
steps. They do not assert native UI behavior or guaranteed delivery.
