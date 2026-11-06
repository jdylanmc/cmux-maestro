# Native peer messaging

Part of [messaging, launch settings, and capacity](../messaging-launch-settings.md). Next page is [Native-child launch policy](native-child-launch-policy.md).

After explicit integration setup, select initial coordinator account and
model in **Agent launch settings**. Then use `launch-coordinator`.
`launch-settings` reports `messagingInstalled` separately from saved-account/
model `ready`. Neither field proves a recipient loaded its native adapter.
Neither identifies the invoking session's account.
New installed-controller spawns auto-bind exact Copilot session,
generation, and CMUX workspace before launch. They enable CLI native extensions
with `--experimental`. No per-project fixture preparation needed. Ordinary
unmanaged sessions, existing workers, and registered coordinators without a
launcher-owned Copilot session stay **unsupported recipients**. Never adopt or
restart them automatically.

Use global `/maestro` for `maestro_peers` discovery, `maestro_send`, and replies
to the supplied sender address. Any participating same-workspace peer can send,
including siblings and peers from another run. Messaging grants no lifecycle or
process-control rights. Native adapter joins only its CLI-owned session.
It uses `session.send({ prompt, mode: "enqueue" })`. Copilot owns scheduling.
No sidebar, selected workspace, foreground application, terminal keystroke,
composer inspection, acknowledgement, receipt, retry, or completion tracker is
involved. A local-write attempt is **not** a delivery or completion guarantee.
Source package and unchanged confirmed purpose live in `skills/maestro/`.
It has no tool-permission grants in frontmatter. It reuses installed
`/cmux-maestro-native:cmux-maestro-orchestrate` skill for lifecycle operations.
For skill tool, pass `{"skill":"maestro"}`. Only existing lifecycle/icon
plugin slash commands stay namespaced. Global messaging guide is not namespaced.
