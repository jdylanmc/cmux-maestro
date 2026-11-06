# Bounded oversized event projection

[↑ Behavioral parity and proof](../behavioral-parity.md)

The reader keeps its 1 MiB ordinary-line limit, 4 MiB per-session / 8 MiB
per-read I/O budgets and 2,048-line per-session budget. When a line exceeds the
ordinary limit, the streaming envelope seam validates its full JSON structure
but keeps only the event decoder's metadata keys. Tool
start/completion/partial-result payloads, assistant messages, binary assets and
otherwise opaque events (including model diagnostics) therefore keep their
ordinary decoder semantics without keeping arguments, results or message
content. Other known lifecycle events still fail closed when oversized. Unknown
work-lifecycle events still reach the reducer's explicit degradation and are
not treated as harmless model diagnostics.

The streaming validator rejects malformed tokens, invalid UTF-8/escapes,
unpaired Unicode surrogates, duplicate keys (including escaped equivalents) and
invalid/truncated container structure. Bounds are 64 total container levels,
1,024 encoded bytes per key and 65,536 encoded key bytes across open objects.
Arbitrary binary-asset `metadata` and tool-result `structuredContent` maps have
no separate per-object key-count ceiling. Even an empty JSON string key costs
two encoded bytes with its quotes, so the aggregate budget allows at most
32,768 live key entries across open objects. That is a conservative
cardinality bound, not a 64 KiB heap-allocation limit: Swift String/Set storage
and frame overhead come on top, with cardinality bounded by the same budget and
depth limit, and wide maps can cost more overhead than narrow ones within it.
The decoder's CodingKeys separately fix retained projection-field cardinality,
so admitting wider opaque maps adds no projected fields. Arrays and opaque
strings are scanned, not buffered.

Selected scalar retention is capped at 2,048 encoded bytes per field. A scalar
over that cap remains present but unusable to the decoder; it is never silently
omitted or defaulted. Irrelevant fields of opaque events stay ignored. The
final projected envelope must fit the unchanged ordinary-line limit. These
resource bounds can conservatively reject otherwise valid pathological JSON;
they do not permit clearing an earlier reader error.

Work is linear in consumed bytes with bounded stack/key storage. Crossing the
line limit also scans the already-buffered prefix once (at most 1 MiB with
defaults), without rereading or accumulating the rest of the payload.
Publication still needs a complete newline and a verified file/identity
boundary. Torn appends keep the previous complete observation and report
loading, and malformed completed lines keep explicit degradation. No Working or
Idle state is inferred from process liveness, and no persisted tail is
repaired by discarding errors.

`CopilotAssetEnvelopeTests` covers synthetic below/exact/above default and
reduced line limits, ordered/escaped/chunked payloads, malformed and incomplete
JSON, resource boundaries, tool success/failure and wrong-owner/turn/replay
controls, advisory message attribution, and a multi-batch large-history
reader-to-sidebar Working-to-Idle transition. This is source-level recovery
evidence for #121, not installed-app acceptance or proof of every reported
missing/Unknown row.

The wide-map regressions cover 64, 65 and 256 unique keys in asset metadata and
tool structured results, below and above the ordinary line limit and across
chunk boundaries. Their red/green proof corrects the earlier unsupported 64-key
ceiling instead of waiving a producer-contract failure. Duplicate keys and
malformed values after the 64th entry stay rejected; the aggregate-key control
admits exactly 65,536 encoded bytes across open objects and rejects 65,537.
