# Hook-owned binding retirement

Issue #336, owner decision: preserve the newest verified-dead binding per
workspace/surface for ended-row presentation. Retire only superseded dead
bindings. This narrows cleanup, not reader correctness (ADR 0010).

## Authority and proof

See [authority and proof](binding-retirement/authority-and-proof.md).

## Coordination and durability

See [coordination and durability](binding-retirement/coordination-and-durability.md).

## Bounds and failure

See [bounds and failure](binding-retirement/bounds-and-failure.md).
