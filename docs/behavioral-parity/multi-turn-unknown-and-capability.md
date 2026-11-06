# Multi-turn child identity: unknown turns and capability

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Multi-turn child identity and completion attribution](multi-turn-child-identity.md)

**Missing current-turn proof remains Unknown.** The earlier review packet did
not establish message tags; its negative regressions remain intact:
`interleavedUntaggedFollowUpNeedsOwnedProofNotGlobalChronology`,
`repeatedProducerShapedUntaggedFollowUpsRemainExplicitlyUnknown` and the matching
reader/tree regression preserve the child's name/kind/ancestry but report
Unknown / `ambiguousTurn`, including repeated follow-ups. The global chronological
chain is not treated as ownership proof. Partial, malformed, null, conflicting,
wrong-owner and replayed message tags cannot borrow a current parent link.
Unusable advisory message metadata does not suppress the whole session; a
completion lacking another valid anchor reports the explicit ambiguity.
Legacy untagged same-owner envelope linkage and current-tool-origin controls
remain supported. A tool first observed after a gap still cannot attest a turn.

Capability is private, bounded reducer state: strict boolean configuration in a
timestamped initial spawn window, before any child turn, with one admission per
observed child ID. Missing/late configuration, missing spawn evidence,
known old timestamps and reused child IDs cannot grant continuation, even if the
old child became Unknown and was retired before its configuration was observed.
Explicit false revokes it. Failed/cancelled child outcomes, scoped abort/error,
shutdown/resume and uncertain lifecycle boundaries invalidate it; a root-turn
abort/error does not imply independent background children ended. Retired rows
remain retired. Legacy model projection, including lagging configuration
timestamps, is independent of capability admission. Public snapshots are unchanged.
This fixes demonstrated continuation identity and tagged-message attribution, not every Unknown agent or a
particular screenshot, and does not complete #118/#119, select a shared runtime
architecture, add saved-session resurrection, or grant child control/placement.

Managed report fixtures include the real terminal sequence: `final_answer`,
`assistant.turn_end`, `session.usage_checkpoint`, `assistant.idle`, then `result`.
Only non-content terminal bookkeeping is permitted; later assistant/tool work
and post-result events remain rejected. Policy denial requires a failed tool's
structured error code, not words found inside successful output.
Resumed-session empty `session.background_tasks_changed` invalidations are also
accepted as notifications, never as proof that background work finished.
The CLI's ephemeral `assistant.reasoning` auxiliary envelope is ignored without
using or publishing its contents. It is not a new reply or a task report.

Owned pre-orchestration installs may lack the newer controller/skill assets when
their signed profile has no orchestration grant. Their exact receipts remain
required for status, preparation, recovery, update and rollback. New sources and
any profile granting orchestration access still require the complete asset pair.
