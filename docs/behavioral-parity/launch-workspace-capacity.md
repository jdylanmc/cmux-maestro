# Launch: workspace capacity

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Legacy fixtures and lock budgets](launch-legacy-fixtures.md) | [Launch: native-child permissions →](launch-child-permissions.md)

Workspace capacity regressions cover persisted CLI configuration, rejected
worker/cross-workspace changes, root/child admission at limits 2, 32, 64 and
128 with retained resources, non-double-counted leases, unknown ownership, and
concurrent admission after an advisory preflight. The 128-boundary proof uses
synthetic retained resources and is not a 128-provider load measurement.

The #167 regressions store 128 synthetic records in workspace A (including
retired history) while B admits independently, keep A unchanged, reject A's
next node, and race last-slot registrations in both workspaces. Saved schema-1
reload, complete multi-workspace observer output, workspace retained-resource
bounds and distinct host node/byte protection are checked without real fleets.
The Swift reader accepts 256 nodes across two 128-node workspaces but rejects
129 in one workspace and 1,025 host-wide. Source publication does not upgrade
an older installed reader/controller or demonstrate live activation.

Managed adapter regressions use 128 private A route/socket pairs plus two B
participants: B discovers only B, exchanges one send/reply through the real
local receiver, and refuses cross-workspace routing. Separate checks accept
1,024 host bindings with 128 local participants, refuse 129 local or 1,025
host, and cap directory scans at 2,048 entries. Mixed-case equivalent saved
workspace UUIDs share node/retained quotas without rewriting the original
records, matching the Swift reader's UUID grouping. A decoded observer-wire
control mixes 127 lowercase spellings and one uppercase spelling of the same
workspace UUID: 128 is accepted, and a 129th equivalent spelling is refused.
These synthetic contract tests neither run 1,024 real sessions nor measure
provider latency.
