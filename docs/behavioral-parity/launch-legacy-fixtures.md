# Launch: legacy fixtures and lock budgets

Part of [behavioral parity and proof](../behavioral-parity.md). Previous page is [direct interactive launch](direct-interactive-launch.md). Next page is [Launch: workspace capacity](launch-workspace-capacity.md).

Preserved legacy tests still cover attachment-ticket serialization, late-claim
refusal, strict reports and exact resume. The inherited eight-pending fixture
previously gave each held runtime a ten-second synthetic barrier deadline
while sequentially launching all eight and checking rejection/archive. Its
first runtime could expire before release on hosted runners. That fixture now
uses an owner-held kernel lock released after the admission assertions, not an
elapsed-time assumption. The current capacity regression requires the configured
maximum reservations and eventual results, with any additional launch refused.
That barrier repair did not enlarge a production or CI timeout.

Legacy report fixtures release their synthetic first-turn output after the
launch receipt, keeping post-start protocol assertions separate from the
unchanged rejection of an already-failed first boundary during startup.
Fixture condition waits read committed control state under its shared lock;
an atomically replaced `state.json` alone does not mean observer publication
has finished or the writer has released ownership. Snapshot reads copy bounded,
stable file bytes under that lock, then decode and validate the immutable copy
after releasing it. A gated validation regression proves a new writer can
commit without changing the captured snapshot; malformed and invalid snapshots
still fail. Read-modify-write operations keep their full exclusive transaction
and bounded acquisition waits. Legacy runtime attachment/token reads share the
read lock until the exclusive startup mutation; private ticket guards and
the attachment-file lease remain unchanged. Control-character checks retain
their UTF-8 byte bounds and exact accepted/rejected characters without a
per-character Python scan on every node's stored provider path.
Lock-acquisition budgets scale by `max(1, MAX_LIVE_WORKERS / 8)`, preserving
the original eight-session allowance against the fixed 32-session reference
for serialized durable writes; both ordinary and runtime acquisitions use
that same reference. Per-workspace admission limits (default 32, configurable
from 1 through 128) do not shrink or enlarge these waits.
The 50ms retry interval, immediate zero-wait behavior, lock modes and failure
on exhaustion remain unchanged; this does not extend launch/result deadlines
or retry a non-contention failure. Deterministic clock tests use real contended
locks to prove both successful acquisition and bounded refusal at several
reference capacities. This reference-scaled budget is an explicit policy
change, not an inference that shorter critical sections alone fixed CI.
The pending-capacity fixture scales its bounded six-second result wait by the
same factor: its old wait must not expire before an allowed runtime acquisition
can finish. This synthetic allowance changes no production result deadline,
still requires every exact completed report and provider call, and preserves
simultaneous maximum reservations, over-cap refusal and archive protection.
