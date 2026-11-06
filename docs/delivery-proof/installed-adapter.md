# Installed adapter wiring

Part of the [native delivery proof](../delivery-proof.md). Previous page is [Installed implementation: checkpoint and validation](installed-validation.md). Next page is [Parent-owned installed-product verification](installed-verification.md).

The existing explicit production **Enable Copilot Integration** action now
packages and writes the shared adapter and minimal native loader under
`~/.copilot/extensions/maestro/`, lifecycle/icon plugin skills, and a private
`Orchestration/bin/messaging.json` configuration. Validation app identifiers are
still denied installation, and app construction has no writes. Setup changes no
Copilot settings, shell files, host selection or other plugins. The global
extension discovery path and SDK import mechanism are documented by the inspected
Copilot SDK's `docs/extensions.md`; SDK resolution is CLI-owned, with no npm
dependency, separate Copilot client, credential read or permission callback.

Each new installed-controller spawn automatically creates an exclusive
launcher-owned binding for its exact node/session/generation/workspace, in an
ordinary working directory. The existing account/model pinning is required;
native-extension launch uses `--experimental`. The loader does not join or add
tools unless those environment identities match a private binding and the
CLI-supplied `SESSION_ID`. Existing coordinators have no launcher-bound session
and cannot receive. No adoption or hidden coordinator adapter is implied.

The same transport now supports `maestro_peers` and `maestro_send` for any
participating same-workspace peers, across sibling branches/runs, without
changing ancestor-only lifecycle authorization. Installed addresses add
`generation`. Sender/return addresses are bound, not caller-supplied; capabilities
never appear in tool output or native prompts. Tools expose participation, not
liveness. Before every tool use or native submission, the adapter rechecks its own
binding. Stale/removed identities fail closed. The unchanged fixture interface
continues to use `maestro_proof_*` and its historical two-peer address shape.

Native children own their sockets; normal provider exit retires the exact
binding/socket, with offline status/archive cleanup for interrupted supervisors.
No route is unlinked to make a duplicate launch work. Uninstall removes the
entry point and new-launch configuration, not live bindings/adapters. Conversation
replacement, restart or missing/unsupported CLI extension APIs do not trigger
adoption, restart, keystroke fallback or retries.
