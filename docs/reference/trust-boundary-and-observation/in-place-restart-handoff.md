# In-place restart handoff

Part of [Trust boundary and observation](../trust-boundary-and-observation.md). Previous page is [Data and trust boundary: hooks, bindings and locations](data-and-trust-boundary.md). Next page is [Controller, hook shell and sidebar reads](controller-hook-shell-and-sidebar-reads.md).

Copilot `/restart` and `/update` keep the bound CLI process alive as a parent.
The same session continues in a new direct child, which takes the session's
`inuse.PID.lock`.

The helper replaces a binding whose recorded owner is still alive only when
all exact evidence agrees:

- The hook's own owner is that live owner's **direct child**: same user,
  parent PID equals the recorded owner, started after it.
- That child holds the session's **only** live marker.
- The request's session, workspace and surface equal the binding's.

Only `bind` does this. Appearance and proof still require the bound owner.
The helper first archives the superseded binding in `retired-bindings`, in the
same digest format as [retirement](../binding-retirement/coordination-and-durability.md).
If the archive fails, the old binding stays.

Repeated restarts follow the chain one direct child at a time from the
**current** bound owner. A grandchild, sibling, older child, second live
marker, placement mismatch or session mismatch still refuses
(`superseded`/`noOwner`).

The sidebar verifier accepts the same case read-only as alive: a live bound
owner whose direct child holds the only live marker. The row therefore
recovers before the next hook. The verifier never writes bindings.

This is the controller's custody rule
([ADR 0025 amendment](../../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md#amendment-2026-11-05-observer-binding-follows-an-in-place-restart)),
plus start ordering. The helper's own proof must also identify the exact owner it
selected, so a lock that moves to a restarted child mid-check cannot prove the
old parent. No title, path or chronology is involved. The human no longer
needs to exit fully and `--resume` after a restart.
