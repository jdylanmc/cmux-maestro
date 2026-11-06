# Bounded oversized event projection

Part of [behavioral parity and proof](../behavioral-parity.md).

The reader retains its 1 MiB ordinary-line limit, 4 MiB per-session / 8 MiB
per-read I/O budgets, and 2,048-line per-session budget. When a line exceeds
the ordinary limit, the existing streaming envelope seam validates its full
JSON structure while retaining only the event decoder's metadata keys. Tool
start/completion/partial-result payloads, assistant messages, binary assets and
otherwise opaque events (including model diagnostics) can therefore preserve
their ordinary decoder semantics without retaining arguments, results or
message content. Other known lifecycle events still fail closed when oversized.
Unknown work-lifecycle events still reach the reducer's explicit degradation;
they are not treated as harmless model diagnostics.

The streaming validator rejects malformed tokens, invalid UTF-8/escapes,
unpaired Unicode surrogates, duplicate keys (including escaped equivalents),
and invalid/truncated container structure. Bounds are 64 total container
levels, 1,024 encoded bytes per key and 65,536 encoded key bytes across open
objects. Arbitrary binary-asset `metadata` and tool-result `structuredContent`
maps have no separate per-object key-count ceiling. Even an empty JSON string
key costs two encoded bytes including its quotes, so the aggregate budget
implies at most 32,768 live key entries across the open objects. This is a
conservative cardinality bound, not a 64 KiB heap-allocation limit: Swift
String/Set storage and frame overhead are additional, with their cardinality
bounded by the same budget and depth limit. Wide maps can cost more overhead
than narrow maps within that bound. Retained projection-field cardinality is
separately fixed by the existing decoder's CodingKeys; admitting wider opaque
maps does not add projected fields. Arrays and opaque strings are scanned,
not buffered.
Selected scalar retention is capped at 2,048 encoded bytes per field. A scalar
beyond that cap remains present but unusable to the existing decoder, never
silently omitted or defaulted. Irrelevant fields of opaque events stay ignored.
The final projected envelope must fit the unchanged ordinary-line limit.
These resource bounds can conservatively reject otherwise valid pathological
JSON. They are not permission to clear a previous reader error.

Work is linear in consumed bytes with bounded stack/key storage. Crossing the
line limit also scans the already-buffered prefix once (at most 1 MiB
with defaults). It does not reread or accumulate the remainder of the payload.
A complete newline and verified file/identity boundary are still required for
publication. Torn appends retain the previous complete observation and report
loading. Malformed completed lines retain explicit degradation. No Working or
Idle state is inferred from process liveness, and no persisted tail is repaired
by discarding errors.

`CopilotAssetEnvelopeTests` covers synthetic below/exact/above default and
reduced line limits, ordered/escaped/chunked payloads, malformed and incomplete
JSON, resource boundaries, tool success/failure and wrong-owner/turn/replay
controls, advisory message attribution, and a multi-batch large-history
reader-to-sidebar Working-to-Idle transition. This is source-level recovery
evidence for #121, not installed-app acceptance or proof of every reported
missing/Unknown row.

The wide-map regressions cover 64, 65 and 256 unique keys in asset metadata
and tool structured results, both below and above the ordinary line limit
and across chunk boundaries. Their red/green proof corrects the earlier
unsupported 64-key ceiling rather than waiving a producer-contract failure.
Duplicate keys and malformed values after the 64th entry remain rejected;
the aggregate-key control admits exactly 65,536 encoded bytes across open
objects and rejects 65,537.
