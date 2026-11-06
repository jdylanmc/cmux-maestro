# Temporary status observation loss

[↑ Trust boundary and observation](../trust-boundary-and-observation.md) | [← Controller, hook shell and sidebar reads](controller-hook-shell-and-sidebar-reads.md)

Confirmed first status/visibility slice of #119 keeps existing bounded
reader and two-second polling pause. Ordinary updates should appear in roughly
2-3 seconds. 10 seconds or more is too slow. Practical responsiveness
goal. It is neither a new session cap nor a reason to increase read bounds.

When ordinary read fails or reliable observation expires, sidebar keeps
exact subject's last known **visual status for five minutes**. Then quietly
shows **Status unavailable**. Fresh valid observation restores current status.
Idle chat is not observation loss: verified unchanged event-file boundary is
still fresh observation. Replayed or older evidence cannot restart grace.

Display memory is separate from current session evidence. Eight-second
trust limit unchanged. Retained status grants no identity, focus,
acknowledgement, dismissal, permission or lifecycle authority. Access denial,
invalid/ambiguous identity, confirmed removal/replacement, and changes to
window, placement, grants or managed generation invalidate retained display.
Recovery after those boundaries requires new valid observation. Unreadable
cached observation cannot seed display memory for new scope. Unsupported
child lifecycle events keep their warning and unknown child state. They do not
suppress independently validated sibling chats.
Partial data can also contain fresh, valid unknown status. That alone is not
observation failure. It does not remove observation before reconciliation.
Internal tasks keep original real open parent, without actionable stale
outcomes. Actual open background tabs stay reachable through current host
metadata. Never fabricate unknown chats without real open surface.
Browser replacing terminal cannot inherit terminal's agent observation.

 Possible 100-chat day
remains nonblocking goal. This slice does not complete #119. It does not authorize
installation, broader settings architecture, or lifecycle changes.

[Regression workload](../../evidence/reference.md#temporary-status-observation-loss).
