# Host safety limits

[↑ Messaging, launch settings, and capacity](../messaging-launch-settings.md) | [← Workspace launch capacity](workspace-launch-capacity.md) | [Legacy bounded-worker compatibility →](legacy-bounded-worker-compatibility.md)

Independent **host safety limits** bound the shared store: 1,024 total nodes
(including leases), 1,024 retained resources, 128 configured workspace-limit
entries, and 1 MiB each for state and observer/icon output. Preflight exposes
`hostStoredNodes`, `hostNodeLimit`, `hostNodeSlotsRemaining`,
`hostRetainedResources`, `hostRetainedResourceLimit`,
`hostRetainedResourceSlotsRemaining`, `hostStateBytes`,
`hostStateByteLimit`, `hostStateBytesRemaining`, `hostCapacitySettings` and
`hostCapacitySettingLimit`, plus `hostStateByteWarning` (true at 80% of the state
byte limit). These are distinct from
workspace allowances. A host protection refusal names its host bound.
Current byte room is advisory, not a guarantee that a proposed record fits.
Actual serialized state/projections are checked before external creation.
Maestro does no automatic pruning, quota bypass, or state reset. One compaction runs on
every state write (#280, [ADR 0010](../../adr/0010-history-fails-open-replay-fails-closed.md)
amendment): an ended node (`resource-retired`, `terminal-disappeared`,
`process-disappeared`, `launch-failed`, `startup-failed`) with no launch lease, archive in
progress or unresolved surface moves its `task` and `copilotExecutable` into the owner-only
`control/retired/<node-id>.json`, keyed by generation, and drops its `launchPath`. Every
other field stays. An unreadable or oversized archive keeps the payload in state. Archiving
a node removes its archive. Older controllers still read compacted state: the executable
and PATH are both absent, as on a registered root.
Schema-1 saved states stay readable. Older installed readers/controllers
keep their previous bounds until an explicitly authorized upgrade. Source
publication alone does not activate the multi-workspace allowance (#167).

Shared managed-message route scan has matching finite host bounds:
1,024 private bindings and 2,048 directory entries (route/socket pairs), with
at most 128 participants in the responding workspace. Other-workspace bindings
are validated but omitted from its peer list. Send/receive keep exact address,
generation, capability, and frame/body checks. Legacy proof transport is unchanged.
Saved schema-1 UUID spellings share a canonical workspace census without
rewriting ownership records or migrating the store. Equivalent case spellings
cannot obtain separate node/retained allowances.

Lock acquisition keeps the existing 32-session reference
policy: ordinary waits stay bounded to 4 seconds, two-second waits to 8 seconds,
and zero-wait requests stay immediate, regardless of workspace capacity.
Upstream activation ordering and installed-runtime validation are separate.
