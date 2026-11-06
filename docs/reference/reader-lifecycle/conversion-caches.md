# Conversion caches and acceptance

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← File-driven reader wakeups](reader-wakeups.md) | [Snapshot schema and validation →](snapshot-schema.md)

The polling adapter retains a bounded conversion cache for at most 64 sessions.
It compares the complete current observation except `observedAt`, reuses only
equal conversions, and always publishes the current observation and envelope
timestamps. Placement changes invalidate the cache, and absent sessions are pruned.
Duplicates and overflow remain in the output instead of being silently
deduplicated or dropped. This skips repeated child/legacy-hierarchy conversion, not reader,
identity, process-liveness or deadline work. Surface-row hover cards are resolved
on demand rather than during hidden row rendering, using the same lazy provider
and open/update revalidation as agent rows. Any surface without a hover
connection exposes neither a preview keyboard hint nor a preview action, and
availability is checked without constructing the card. A status-only
session also has no preview target, because the shared surface-row session
target excludes retained status for previews, inspection, tags, icons, pets and Beats. Retained
status remains visible, and surface inspection/navigation remain available.

Per-session temporal projection and child assessment have separate reuse
boundaries. Session-only changes and history/attention expiry still reproject
the affected session, but do not revalidate unchanged child payloads. The child
cache retains at most 64 valid assessments, keyed by exact provider/session
identity, schema, error path, legacy children and flat observation (including
its losslessness flag). It reuses only under a finite envelope timestamp no
earlier than the successfully assessed envelope, so child activity-date
validity cannot regress. Invalid/future evidence is never cached, and time
advancement and rollback rerun the validator when required. Session validation always
runs when projecting. Topology/global context changes clear both caches,
absent identities are pruned, and scope teardown clears retained assessments.
No attention/history/freshness deadline or liveness check is skipped.

The three native callback tests are inventoried local opt-in acceptance in
`scripts/local-ui-acceptance.json`, enabled with
`CMUX_MAESTRO_LOCAL_UI_ACCEPTANCE=1 ./scripts/test.sh --focused SidebarFileWatcherAcceptanceTests`.
OS daemon/vnode scheduling is not a deterministic required-CI dependency. Required
tests inject event delivery into the production registration plan, including
30,000 events under 1,000 non-shown directories over a controlled 60-second
schedule: zero event-driven reads, 30 fallback reads (0.5/s after initial discovery).
That deterministic work count does not measure wall-clock throughput or CPU.
No timing allowlist exception is added or hidden by the opt-in inventory.
Native callback and controlled-clock tests are not installed ExtensionKit proof.
After authorized installation, measure idle CPU with
`python3 scripts/measure-sidebar-cpu.py --pid <exact-extension-pid> --output <new-private-directory>`.
Compare matched workloads before/after (target <=2% idle CPU). For latency, use
only a generic hosted fixture and record durable-change time to the first matching
pixel/accessibility update, with sample count/distribution. The coordinator
owns these acceptance checks, and this change includes no production install.
