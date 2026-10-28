# Agents self-report enum-only moods

Owner decision for #376 (route R3), delivered by #380: a managed agent may
self-report one of `happy`, `celebrating` or `confused` for its own exact
session, or `clear` to withdraw it. This is a narrow authored-content
exception, like agent tags (ADR 0026) and notifications (ADR 0030): an enum
value, never free text, a reason, observed content, transcript inference or a
tool payload. There is no `thinking` report; derived presentation covers it.

The native `maestro_mood({mood})` tool and controller `mood --self` resolve the
caller from its exact managed node, run, session, workspace, surface and
generation, live provider ancestry and sole session custody. The unsandboxed
controller reuses the appearance helper's native proof and revalidates under
its existing mutation lock, then atomically writes a separate private
`observer/moods.json`. Lifecycle records, appearance records, Beats and
notifications are untouched. No enrollment, reload, grant or permission
expansion follows from reporting.

The sidebar reads the file under its existing observer grant (ADR 0001, 0020).
It gains no writable store, helper, socket or timer. Strict validation matches
all six identity fields against the current verified binding (ADR 0002).
Invalid mood data disables only the mood overlay, never the hierarchy or
attention (ADR 0010). A claim is labelled self-reported and is never evidence
of work, success or completion (ADR 0003). Question, permission, failure and
Gone must win over it; that resolver (#382) and art (#383) are separate.

Store rules: one current claim or `clear` tombstone per node, with a
controller-issued sequence that increases across the node's generations. Only a
newer verified generation with the same run, session, workspace and surface
replaces a node's claim. An unchanged claim is a no-op. Limits: 1 KiB per
record, 1 MiB per file, 1,024 nodes, 128 per
workspace. At most one distinct non-clear change per three seconds per exact
identity; `clear` is exempt and never refills the allowance. Refusals are
bounded reason codes with no queue or retry. A controller-issued
`lastChangedAt` enforces that limit only; readers never use it as a clock.

Capacity: a full store refuses without eviction, including claims and
tombstones for nodes no longer in the lifecycle store. Unlike the tag store's
retention policy (ADR 0026), neither archive nor reporting reclaims mood slots.
Sequence exhaustion also refuses; exact ordering evidence is never discarded
to admit another report.

Cold start: a reader baselines existing sequences and does not show those
claims, so an old `happy` never replays after a restart or rebind. Reports made
while no reader observes them are intentionally lost. Readers keep bounded
high-water marks without eviction, even for nodes absent from the store and
hierarchy; a missing, malformed, mismatched or equal-sequence record cannot
restore an expression. Exhaustion disables only the overlay.

Why: owner-selected R3 gives agents a terse, optional way to express a verified
good outcome, a significant win or missing meaning without inventing feelings
from observations, while keeping authority to the exact caller.

Rejected: mood fields in lifecycle or appearance records (couples cosmetics to
evidence); free-text or reasoned moods (privacy, ADR 0022); `thinking` (overlaps
derived state); transcript or tool-result inference; queued or retried reports
(stale playback); reusing the Beats grant or `maestro_notify`.

Consequence: same-user processes can edit the file; readers check shape,
ownership, privacy and exact binding, not cryptographic authorship. Exact-self
proof establishes who reported, not whether the report is true. Contract:
[self-reported moods](../reference/self-reported-moods.md).
