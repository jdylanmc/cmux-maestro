# Alpha installation: integration checkpoint

Part of [behavioral parity and proof](../behavioral-parity.md). Previous page is [retired slots and native publication](install-retired-slots.md). Next page is [Alpha installation: plugin identity and disabled state](install-plugin-state.md).

`build-register.sh` now hands its verified artifact to the same `install`
entrypoint. It no longer separately registers the development extension.
The installer calls a production-only, non-UI bridge with a transaction UUID
and stable application path. It prepares an owned integration checkpoint before
the app exchange, applies Copilot, verifies provider discovery and exact app
registration, and only then commits current/previous app retention. An identical
app also checks integration; a fully current repeat skips resource replacement
and official plugin mutation.

The durable integration checkpoint is private `0600` data in
`Orchestration/install-transaction.json`, outside the sidebar's granted
`Copilot/` and `Orchestration/observer/` prefixes. No permission is broadened.
Recovery validates the schema, fixed file paths, original modes/absence,
expected resource bytes and transaction UUID. It keeps observers inactive while
compensating through official install/uninstall at the stable owned source,
restores prior settings only across verified CLI normalization, and verifies
the original public plugin/hook inventory before the app is restored.
The fixed owned installed payload is verified too. If source and installed
copies differed before an interrupted setup, compensation temporarily supplies
the saved installed payload at that same source, verifies official replacement,
then conditionally restores the original source bytes. Provider-private state
and unrelated plugin directories are never rewritten.
Unexpected concurrent content or disable changes refuse compensation rather
than being overwritten. Failed compensation retains the checkpoint.

Receipt publication now has a write-ahead exact-image boundary. Before a
staged/current observer receipt can change, the checkpoint validates its
current image and durably records the complete intended bytes/mode/source
binding. Missing-`after` recovery cannot substitute generation equality for
that authorization. Tests change plugin identity and source path/ID without
changing the generation, and require preserved edited bytes/resources and
journal with no compensating provider mutation. A real compiled-bridge exit
after current-receipt publication but before the final snapshot still recovers.

The existing finite command guardian also covers nested provider groups.
Standalone provider processes retain their independent groups and original
timeout/cancellation cleanup. Coordinated providers use the same grouping but
wait behind a launcher gate until the trusted bridge synchronizes their group
IDs into the inherited install-guard record; providers never inherit that
descriptor or its environment. The guardian re-reads and drains the complete
record after bridge exit. If the guardian also terminates, fresh recovery refuses while any
recorded group survives. Actual compiled bridge/provider gates prove this for
forward and compensation paths, with and without guardian death, preserving
unrelated processes. The old observed late-write-after-restoration results
are retained as red evidence, not relabeled as supported behavior.
