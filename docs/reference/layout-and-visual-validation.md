# Taskboard, layout, and visual validation

Taskboard, Beats, details, density, layout storage, pixel validation. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

CMUX's own shortcut instead of renaming it. **Active window** footer has a drag handle on
its top divider. Shrink to pet row; grow to half the sidebar. Double-click resets. Size is remembered.
Taskboard renders only in sidebar. No reusable or movable content tabs. Extension SDK offers no content-tab host. Taskboard is a state board: one card per agent session.
Cards group under headings with count: **Waiting on you**, **Working**, **Failed**, **Idle**, **Finished**, **Unknown**.
Card shows agent icon and title, current activity, workspace with model on right. Card shows branch only when agent works in git repository or linked
worktree (worktrees labelled). No sub-agent, skill, shell or
internal-task rows; those stay in Hierarchy. Select card to focus its terminal.
Beats opens native popover. Create, edit,
enable, disable, delete recurring prompts there. Icon lights while a Beat is enabled.
An agent row (managed agent, single-session terminal, or listed Copilot session) and a
Taskboard card show the same Beat icon as their rightmost item, after collapsed summaries,
pin and unread badges and the row's actions (…) slot, at rest and on hover, with its glyph
flush to the row's trailing content edge (where the header controls end), when that row's
exact session UUID has an enabled Beat. No title, path or label matching; retained context
and status-only rows and internal tasks get none. Lit when the session is alive in a current
observation (the freshness hover cards use); dim when it is not running, stale, hidden or
disconnected. The lit glow is one Core Animation opacity pulse (about 1 second each way) in
the render server, removed under Reduce Motion (static glow) and while the icon has no window
or is hidden. Clicking it opens Beats scoped to that session, or rescopes an open panel in
place, without focusing the row or navigating CMUX. A scoped **New Beat** targets only that
session; **Show all** returns to every Beat and is absent while a form is open, so a draft
is never discarded. Opening Beats from the header shows every Beat.
Beats run on Copilot's own scheduler. Maestro extension loaded in each CMUX Copilot
session asks the controller (`beats-snapshot`) for that session's enabled Beats and
mirrors them into native cron schedules; it never parses `beats.json` itself. An invalid
store changes no schedule. No clock process,
managed launch or socket frame involved. Beats are only on or off. Session
re-registers its enabled Beats on every start. Copilot-specific
scheduling call is isolated in `createScheduleGateway` in installed adapter.
CMUX does not expose keep-awake, so no Fermata control.
Settings and separate Details inspector popover have explicit Close controls.
Inspector is keyboard-accessible and scrolls independently. It preserves full metadata
and Other activity. It revalidates window, placement, session, run and generation
identity against current permissions. Workspace-only details require current
workspace access, not surface access. Paths stay independently permission-gated.
Surface and session details still require surface metadata. Replaced or revoked subjects show
unavailable message; never silently keep old data. Escape or Close
dismisses only inspector. Footer has no Close or manual-pin override.
Rows use concise state labels, not diagnostic walls. Blocked/failed state, incomplete ancestry,
omitted active work and attention stay concise and visible. Select state
glyph's Details action to open inspector, not a replacement footer. Managed workers resolve verified
model metadata only when both controller-issued Copilot session UUID and
surface match one fresh, live observation. Coordinators use one fresh, live,
unambiguous observation on exact surface. Same names, directories, stale
or ended observations, unconfirmed owners, surface mismatches and ambiguous
coordinator sessions never participate. Context
usage/window size omitted: current producer has no documented numeric source.
Cumulative API tokens and context tiers never show as context occupancy.
Full authorized paths and stable IDs remain in deliberate inspection. Successful
tab focus and opening details mark that scope's nonblocking notices as read.
Passive footer refresh, hover, copying and expansion never mark anything read,
focus a tab, send input, or change lifecycle. No interaction approves or answers
a request. Existing explicit host-focus observation semantics unchanged.

For unmanaged terminals with exactly one observed session, state and children
show on the named terminal row. No duplicate provider/ID
heading. Multiple sessions stay individually inspectable; none is guessed as
current owner. Passive skill/shell history moves to selected session's
**Other activity** disclosure; Taskboard does not list it. Agents, structural
ancestors, active/blocked/failed work and outstanding attention stay in outline.
Exception: ordinary running shell invocations. Verified, unambiguous leaf
commands fold into quiet metadata line of exact owning session or
agent, such as "Running a command". Concurrent commands are counted. Blocked,
attention-bearing, unresolved and structural shell rows stay visible. A nested shell
command that merely exited with error is not an outline row. It moves to
session's **Other activity** disclosure, so a stray `bash invocation` failure no longer
draws a red row under an agent.
Complete shell records remain available in details. This is
presentation-only: raw activity evidence, lifecycle state and counts unchanged.
Incomplete-history context and collapsed-branch counts stay with owning
row, not on standalone diagnostic rows. Chevron needs no "Branch collapsed"
caption. Registration is neutral, not a claim that an agent runs. Stale
managed evidence and unconfirmed/ended process ownership cannot show a live state.

With or without managed graph, same outline groups real CMUX
surfaces and valid inferred Copilot sessions under workspace headers. Working
directory labels are home-relative where applicable, never inferred Git
branches. Uncertain ownership and incomplete evidence stay honest glyphs or
summaries. Incidental diagnostics stay behind selection or settings.
Taskboard remains available from its header button. It places every
session in bucket for its observed state, even with no attention or child rows.

Healthy outline has no diagnostic paragraphs. **Maestro** leads header.
Six existing actions form a right-aligned group of 28-point buttons with
2-point gaps. They do not stretch across sidebar. Source availability is a header
indicator with full help and accessibility text. Incomplete evidence is marked on
its owning row. Blockers, attention and omitted active work stay visible.
Workspaces use primary 12-point semibold names, boxed disclosure and section rule.
Rows keep chosen identity glyph in consistent 24-point column. Directory
context uses observed basename, never a guessed workspace name or Git branch.
Complete home-relative paths stay in hover, accessibility and Details. Do not repeat unavailable
workspace/project/path lines on every row.
New grouping selectors, pane headings and tags from design
prototype are deliberately separate scope; no decorative substitutes shown.
Header gear remains entry for density and stored preferences. Saved
expansion, retention, acknowledgement, navigation and source records are preserved.
Outline's activity filtering is presentation-only.
When several source warnings apply, overview keeps primary warning
and omitted active-work count visible. Its Details disclosure lists every reason.
Current host's overlaid footer has 50 points of reserved clearance.

Sidebar **settings** includes **Compact** and
**Comfortable** (more room and larger native detail text) density. Hierarchy
and Taskboard both keep same sessions and independent focus actions.
Dismissal and acknowledgement stay in Hierarchy. Narrow rows stack actions.
Full paths remain available to accessibility and tooltips.

Outline uses 5-point side gutters (scaled for Comfortable), 8-point shallow
nesting and 4-point increments beyond level three, bounded to 32 points or 12%
of available width. Full Git diagnostics remain in hover/details so titles keep priority.
At eight levels and 280 points, stable overflow slot leaves at least 124 points
for name without hover-time reflow. 50-point host-footer clearance unchanged.

Hierarchy expansion persists by workspace/surface UUID and provider/session/
child identity—not names, paths or current window. Moves and reloads keep
the setting. New identities start expanded. Reusing same child ID in a
different session/provider does not inherit a collapse. Returning with
same full identity intentionally does. Collapsed ancestors retain visible
running, blocked and attention summaries. Incomplete counts stay labelled.
Collapse never dismisses or acknowledges work and never changes retention.
Internal-task groups and task-child disclosure share exact provider/session/task
identities across both views and reloads, independently of actual child-agent tabs.

Density overrides, collapsed identities and workspace-local idle-task reveal
choices are stored in a versioned
`CMUXMaestroPreview/sidebar-layout.json` record in extension container's
Application Support directory. Coordinated, atomic action-level writes merge
across views/processes. They do not replace a stale window snapshot. Local
views synchronize immediately. Native file-presentation notifications refresh
other processes. Reloads also happen on host/observation updates, activation and
appearance.
Storage is bounded to **2,048 overrides / 1 MiB**. Oldest collapse overrides
are evicted first, which only **expands** branches. Off-window state is never
pruned based on a current snapshot. Unreadable or unknown-schema settings
expand all branches and show recoverable notice. Only **Reset layout
settings** replaces that record. **Expand all branches** preserves density.
Layout reset restores Compact and does not alter history or attention settings.

Sidebar order ([ADR 0021](../adr/0021-sidebar-order-is-maestro-local.md)) is a
separate versioned `CMUXMaestroPreview/sidebar-order.json` record in the same
container, using the same coordinator. It holds one list of CMUX UUIDs per window
(workspaces) and per workspace (surfaces) and is never sent to CMUX. A list is
pruned to present IDs only when that list is saved, and dropped when it matches
CMUX's order again; other windows' lists are never pruned from a current snapshot.
Storage is bounded to **256 lists / 512 IDs each / 1 MiB**. When full, the least
recently changed surface list is evicted first; workspace lists go only when no
surface list is left. Lists for closed workspaces are not pruned before that. Unreadable or unknown-schema files show CMUX's order and a
recoverable notice; only **Reset sidebar order** replaces them. Drag sources are
the row title controls; drops show a 2-point insertion line at the nearer edge of
the whole row, including the children it carries.
All moves and resets go through `SidebarReorderBackend`; the backend is chosen
per kind in `SidebarReorderBackends.make` (always Maestro-local today). Primary
managed agents share their workspace's surface list as a first block, keyed by
their CMUX surface UUID; blocks and pin groups keep their slots. Drag types
`com.jdylanmc.CMUXMaestroPreview.sidebar-order.{workspaces,surfaces}` are declared
under `UTExportedTypeDeclarations` in `CMUXMaestroSidebar/Info.plist`.

Layout's file/store types are thin adapters over same preference coordinator
used by history and acknowledgements. Only layout's mutations and safe eviction
policy remain feature-specific. Existing layout path and version-1 schema
unchanged: no layout migration or rewrite on open. Missing layout
files mean Compact and fully expanded. Reads/refreshes do not create a file.
This lazy mode is explicit; history/acknowledgement migration-on-open unchanged.
Lazy stores observe nearest existing container, so first-file creation in
another process also reaches already-open views, without writing defaults first.
All three records stay separate. Tests and offscreen renders inject all three
storage paths and never fall back to production layout singleton.

### Synthetic layout review images

`./scripts/test.sh` writes offscreen SwiftUI/AppKit PNGs to
`.build/layout-validation/offscreen/`. CI uploads only those PNGs as the
**sidebar-layout-offscreen** artifact (14-day retention), including when tests
fail after producing images. Review both densities at 240 pixels in dark mode,
increased contrast, and long synthetic path/model/nested-label scenarios. Also review
light-mode expansion matrix at 240 and 349 pixels. Dedicated
`managed-*-340x600.png` and `unmanaged-light-340x600.png` fixtures exercise two
workspaces, duplicate names, nested ancestry, long branches and mixed lifecycle
states at target sidebar density. Broader matrix uses a 941-point
viewport. Filenames identify density, scenario, view mode and width.
Renderer checks actual SwiftUI color-scheme and contrast environment.
Per-image JSON records measured scroll viewport/document geometry. Metadata-only
panels also render at both widths to check horizontal containment. Clarity
validation uses matched before/after fixtures, not screenshots of live work.
Its fixed synthetic clock also owns injected freshness timer. Elapsed CI
wall time cannot expire a fixture whose logical clock has not advanced.
Clarity tests also render light/dark icon and status keys, verify each
symbol exists, and confirm output contains actual color accents.
Contrast uses SDK's writable `_colorSchemeContrast` backing key only in
tests, paired with native high-contrast AppKit appearances. No system display
preferences change.

Active-window footer renders all eight light/dark, 240/340-point width and
144/220-point height combinations at explicit native 2x resolution. Exact model
and copy-feedback text is recognized from those pixels without resampling or
language correction. Copy feedback also retains native accessibility and
viewport-containment checks. Wrong, missing, hidden and clipped model controls
must fail the same visibility check. Each text failure reports its image and
recognized lines.
Separate inspector uses native 2x production captures in both appearances.
An independently rendered runtime literal `Model` / `verified-model` pair uses
same compact font and selectable-text modifiers. Every pixel of both lines,
their borders and trailing column must match exactly. Allow only one-pixel
translation. No resizing, OCR spelling aliases or averaged ink score.
Blank references fail explicitly. Wrong, missing, hidden, partially clipped,
wrong-model-with-the-right-value-elsewhere and suffixed values must reject through
same oracle. PNG references/captures and per-image pixel differences remain
with render artifacts. Revoked-subject clearing, no-copy and passive-focus
checks remain in place. Footer OCR and native copy checks unchanged.

Retained native-menu tests capture complete production details popover at
explicit native 2x, including unavailable state after each identity change.
Unavailable heading and both explanatory lines must match an independent
runtime literal reference, pixel for pixel at expected locations: no OCR,
translation or pixel tolerance. Reference uses same native popover shell
for material/text rendering, not production text or a saved screenshot.
Blank-reference checks and light/dark missing, hidden, wrong, partially clipped
and misplaced warning controls exercise both embedded and native-popover captures.
All 12 retained-menu cases keep their identity, copy, attention, navigation and
pinned-subject assertions. Full captures and references use existing
`.build/layout-validation/offscreen/*.png` artifact path. Geometry and exact
pixel-difference sidecars remain beside them locally.

Full-sidebar warning matrix retains both densities, both appearances,
240x400/340x600-point sizes and both waiting/disconnected states (16 captures),
alongside connected-footer geometry and zero-painted host-clearance checks.
Only these natural-language warnings normalize OCR whitespace and lettercase:
`Waiting for CMUX` and `CMUX disconnected. Focus and live status unavailable.`
Both must retain every word and punctuation mark across line wraps. Empty, partial,
wrong-state, navigation-only, substituted-word and missing-punctuation controls
must reject. Each render reports its filename and recognized lines. Exact model,
session-ID, copy and inspector-pixel oracles do not use this normalization.

All metadata is synthetic. Local preferences are isolated for render
tests. Embedded render windows stay offscreen. Native interaction/popover tests
show only their own synthetic windows. These are view captures, not a desktop capture, live
CMUX-host visual proof, system VoiceOver verification or a checked-in OS/font
golden-image comparison. No transcripts, real workspace paths or desktop images are uploaded.
