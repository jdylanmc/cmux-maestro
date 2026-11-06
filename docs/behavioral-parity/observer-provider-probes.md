# Observer registration: provider probe evidence

Part of [behavioral parity and proof](../behavioral-parity.md). Previous page is [dedicated observer registration](observer-registration.md). Next page is [migration and restoration](observer-migration.md).

The 1.0.89 maintenance probe covers public metadata, inactive file staging,
official plugin settings normalization, real-core migration/install/update/
removal, and related/unrelated-key refusal using disposable homes. It makes
zero model calls and does not extend the earlier 1.0.88 event-execution,
running-session reload or global-disable observations to 1.0.89.
That initial conservative unrelated-key refusal is superseded only for the
positively proven unaffected case: complete exact-owned prior keys, all owned
events enabled, and every global disabled key resolved to an unrelated action.
Affected subsets, missing keys and ambiguous metadata still refuse. No settings
migrator, enabled duplicate preview or private key hash is introduced.

The earlier 1.0.88 probes established these separate facts:

| Evidence level | Observed result and limit |
|---|---|
| Source/on-disk format | User version-1 files are accepted independently of plugins. Sources combine, and the provider does not deduplicate them. |
| Public discovery | File-level `disableAllHooks` returns disabled rows but omits their destination disable keys. The actual legacy sorted-key producer and four justified user representations did not preserve legacy keys: normalization changed serialized config order, not inherently source identity. |
| Disable-key mapping | Additive old/new **global** keys preserve all-three and single-event intent in discovery. Repository `disabledHooks` was ineffective even against the unchanged legacy source. These are not event-execution claims. |
| Actual activation | `sessionStart` and `userPromptSubmitted` markers preceded the only quota-rejected model request. Permission-free public `tools.execute` produced `postToolUse` markers. No successful model turn was available. |
| Concrete session cache | Existing disposable-session `postToolUse` retained A after disk changed to B. A fresh session used B. Explicit supported hook reload switched the existing session to B. Other events were not separately re-proved after reload. |
| Global disable limitation | `disableAllHooks:true` did **not** suppress `postToolUse` on the tested `tools.execute` path, including in a fresh runtime. This is not generalized to a successful model loop. |

The implemented fallback is deliberately smaller than a speculative settings
migrator: when a change needs unavailable destination-key mapping, refuse
**before changing the legacy registration**. Never enable a duplicate only to
discover a key, reverse-engineer hashes, drop old keys or approximate a
single-event disable with a new blanket policy. Maestro reads global settings
without writing them. The official CLI can replace `settings.json`; after a
successful command only identical values or an added empty `enabledPlugins`
map are acknowledged, with fresh safe-file checks. Any changed disable or
unrelated value still refuses. An explicit global/file disable preserves a disabled owned
file. Setup does not claim it repaired provider-wide enforcement.
