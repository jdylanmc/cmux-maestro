# Refresh and render cost

[↑ Sidebar presentation](../sidebar-presentation.md) | [← Navigation and ended rows](navigation.md) | [Display clock, expiry and CPU acceptance →](display-clock.md)

Title controls update their hosted label only when SwiftUI updates the content.
Size proposals use `NSHostingController.sizeThatFits(in:)` without replacing the
root, changing the mounted frame, or scheduling another layout. Repeated and
alternating proposals must leave an unchanged label's layout clean.

Orchestration polling retains one bounded decoded value (or decoding failure) per
observer file. It still securely opens and reads each bounded file every two
seconds, comparing exact bytes rather than trusting modification time alone.
Unchanged bytes skip JSON decoding and structural resolution. Validated hierarchy
and icon overlays are cached separately from exact process matching, so a
process-only change does not revalidate or rebuild the hierarchy. Optional-file
removal and malformed replacements never preserve the previous overlay.
Clock rollback revalidates; unchanged future-dated process evidence is rematched
when it enters the accepted clock window. Presentation freshness deadlines still
run independently. File permissions and identity are checked on every read. The published
named snapshot changes only when its value changes, not through an intermediate
unnamed snapshot. The change adds no timer, process scan or filesystem grant.

Copilot event tails at a verified unchanged EOF skip event-byte reads and projection
rebuilding. They still securely open the file and compare descriptor and directory
entry stamps (identity, size, mode, owner, modification and change times); routing,
session and process verification still run. A changed file takes the existing
bounded append/rebuild path. Torn final lines remain incomplete without fast polling.
This optimization covers only unchanged event files. It is not a stat-only
whole-reader pass:
per-session location and appearance metadata still use secure bounded reads.
Binding discovery still checks off-surface files: an in-place reroute can leave
the directory stamp unchanged. Path-component validation checks slash and NUL
in one UTF-8 scan, without caching authorization or bypassing file fences.
Pet frames and status decorations run as render-server animations, not SwiftUI
timelines. They must not drive continuous hierarchy layout between observations.

Workspace placement caches retain only ordered identity, location and freshness
inputs, plus session indices and owner IDs. They never retain session histories.
Raw visibility and history-filtered rows have separate caches. Worktrees,
Sub-agents and collapsed summaries reuse the same indexed ownership evidence.

## Host focus refresh

CMUX does not push a sidebar snapshot when only tab, pane or workspace focus
changes. As a workaround for this host gap, each window's binding pulls its
own connection's snapshot every 500 ms
([ADR 0032](../../adr/0032-refresh-host-focus-while-visible.md)). The pull runs
only while that window's sidebar is visible, connected and CMUX is the active
app. Otherwise no timer runs. Visible means mounted, not on screen: a minimised
or covered window keeps refreshing while CMUX stays active. Hiding the sidebar
stops it, because CMUX unmounts the sidebar.

Becoming active, visible or connected refreshes immediately unless a request is
still unanswered. At most one request
is in flight, and a stop and restart keep it. Three ticks skip an unanswered
request and the fourth re-sends it. A lost connection abandons the request. A
failed pull shows the degraded state and stops refreshing until the host
publishes again: a push, an accepted action or a reconnection. Unchanged
snapshots stop before any model update. The pull only reads. It never moves
focus, sends input or changes unread counts. Activation only gates power. It is
never focus evidence.
