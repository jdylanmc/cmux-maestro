# Managed Git provenance

Part of [behavioral parity and proof](../behavioral-parity.md).

Managed Git branch/worktree labels, verification times and change counts describe
the **assigned directory**, not Copilot's current `/cwd` or a tool's working
directory. The controller's `collect_git_evidence` probes `node.workingDirectory`
via `git_display_metadata`, applies evidence only to the matching run/directory,
and publishes bounded labels/counts through `Orchestration/observer/current.json`.
The sidebar's existing reader validates that projection; `managedGitDetails`
shares the assigned-directory qualifier across inspector, hover, pinned details
and row tooltips. Compact row labels remain unchanged; the count badge identifies
the assigned directory in its caption, tooltip and accessibility description.

The existing 60-second Git freshness checks still suppress current branch/worktree
fields and counts when stale. Last-verified labels remain explicitly historical;
unavailable evidence never proves a non-repository, and detached HEAD does not
require a branch label. CMUX **Surface directory** and **Parent surface directory**
remain separate host reports with unchanged permission and provenance rules.
No dynamic directory collector, worktree identity/grouping key or new grant is
introduced. This correction references #119/#59 without completing either.

`SidebarAgentHoverTests.managedGitConsumersQualifyAssignedDirectoryWithoutChangingFreshness`
covers shared fresh, stale, unavailable, absent, stale-count and detached-HEAD
presentation. Existing pinned-detail and native row-tooltip assertions retain
their identity, freshness and compact-layout checks. These tests require the
unchanged hosted native suite; source inspection or an unsigned build alone
does not establish test execution or installed-host acceptance.

The combined owner/task-depth render supplies its frozen observation clock through
the shared `sidebarPresentationNow` environment seam. Outline placement, retained
context, details, hover and action revalidation use that clock; production still
reads `Date()` on demand, with the same eight-second identity freshness boundary.
`controlledPresentationAgeExpiresRetainedOwnerWithoutChangingObservations`
checks the exact retained-owner label at eight seconds and its expiry at 8.001
seconds in both modes without refreshing observations. Geometry assertions remain
unchanged and failures include native owner labels and observation ages.

Footer model rendering uses the same zero-tolerance native-pixel comparator as
the inspector, against an independent literal `verified-model` reference in its
expected region. All eight production size/theme combinations retain copy and
geometry checks. Both themes also require rejection of wrong `verifled-model`,
suffix, missing, hidden, clipped and elsewhere text. This replaces only the
model-line OCR oracle, not production typography or content; whole-image OCR
misread the visible line in both initial hosted runs. A prior owner-label failure
is consistent with the fixture's frozen clock crossing wall-clock freshness, but
its failure-time labels/ages were not logged, so that historical cause remains
inferred. Repair execution and sensitivity evidence still require hosted CI.
