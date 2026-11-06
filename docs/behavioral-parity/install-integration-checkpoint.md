# Alpha installation: integration checkpoint

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Retired slots and native publication](install-retired-slots.md) | [Alpha installation: plugin identity and disabled state →](install-plugin-state.md)

`build-register.sh` hands its verified artifact to the same `install`
entrypoint instead of registering the development extension separately. The
installer calls a production-only, non-UI bridge with a transaction UUID and the
stable application path. The bridge prepares an owned integration checkpoint
before the app exchange, applies Copilot, verifies provider discovery and exact
app registration, and only then commits current/previous app retention. An
identical app still checks integration; a fully current repeat skips resource
replacement and official plugin mutation.

The durable checkpoint is private `0600` data in
`Orchestration/install-transaction.json`, outside the sidebar's granted
`Copilot/` and `Orchestration/observer/` prefixes, so no permission widens.
Recovery validates the schema, fixed file paths, original modes/absence,
expected resource bytes and transaction UUID. It keeps observers inactive while
compensating through official install/uninstall at the stable owned source,
restores prior settings only across verified CLI normalization, and verifies
the original public plugin/hook inventory before restoring the app. It also
verifies the fixed owned installed payload. If source and installed copies
differed before an interrupted setup, compensation temporarily puts the saved
installed payload at that source, verifies official replacement, then
conditionally restores the original source bytes. Provider-private state and
unrelated plugin directories are never rewritten. Unexpected concurrent content
or disable changes refuse compensation instead of being overwritten. Failed
compensation keeps the checkpoint.

Receipt publication has a write-ahead exact-image boundary. Before a
staged/current observer receipt can change, the checkpoint validates its current
image and durably records the complete intended bytes, mode and source binding.
Missing-`after` recovery cannot substitute generation equality for that
authorization. Tests change plugin identity and source path/ID without changing
the generation, and require the edited bytes/resources and journal to survive
with no compensating provider mutation. A real compiled-bridge exit after
current-receipt publication but before the final snapshot still recovers.

The finite command guardian also covers nested provider groups. Standalone
provider processes keep independent groups and original timeout/cancellation
cleanup. Coordinated providers use the same grouping but wait behind a launcher
gate until the trusted bridge syncs their group IDs into the inherited
install-guard record; providers never inherit that descriptor or its
environment. After bridge exit the guardian re-reads and drains the complete
record. If the guardian also terminates, fresh recovery refuses while any recorded
group survives. Real compiled bridge/provider gates prove this for forward and
compensation paths, with and without guardian termination, and leave unrelated
processes alone. The earlier late-write-after-restoration results stay recorded
as red evidence, not relabeled as supported behavior.
