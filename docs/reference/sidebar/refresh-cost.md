# Refresh and render cost

Part of [sidebar presentation](../sidebar-presentation.md). Previous page is [Navigation and ended rows](navigation.md). Next page is [Display clock, expiry and CPU acceptance](display-clock.md).

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
