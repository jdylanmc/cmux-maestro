# Sidebar presentation

Outline rows, Git evidence, icons, previews, copy, state cues, headers. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

Default view: restrained workspace outline. Primary semibold workspace headers
contain explicit coordinator → worker → nested-worker rows. Guide lines show hierarchy.
Disclosure is durable, keyed by stable node identity. Each row leads with its safe name.
Below it, one quiet kind/location line appears when the external controller verified
those facts from the explicitly assigned working directory (Assigned directory). Worktree label = verified
repository root basename. Branch label comes from `git symbolic-ref`.
Detached `HEAD` omits the branch, keeps the verified worktree. Non-Git
directories, missing directories, timeouts, invalid output, overlong output and
failed root queries publish no Git labels. Never call such a directory a
worktree. Controller refreshes exact assigned-directory evidence at bounded
worker heartbeats, turn boundaries, follow-up queueing and explicit status checks.
Each projection carries a separate Git evidence status and capture time. Stale
verified locations stay useful context. They get a static unverified-state cue and
explicit **last verified** hover/details and accessibility qualification. Never present them as current
Git state. Omit unavailable evidence. Probes batch by assigned directory and run outside the global
state mutation lock. Sandboxed sidebar never runs Git. It never receives the
private full assigned path through observer metadata.

Managed rows show concise worktree context beside the exact state cue. Hover,
Details and the existing pinned footer keep Git diagnostics. Fresh Git evidence
carries a changed-file count and **+green / -red** tracked-text line counts
against `HEAD` (staged and unstaged changes combined). File totals include
untracked files and binary changes. Line totals exclude them and submodule
contents. Renames count once. Conflicts, unborn `HEAD`, failed or oversized
probes, and stale evidence never become zero counts. Counts are sampled, not an
atomic snapshot of concurrent edits. Missing current counts stay unavailable.
Count freshness has its own timestamp, independent of branch metadata refreshed
by older supervisors.
Hover cards and pinned details reuse one wrapping semantic Git summary. It includes
the assigned-directory label, comparison basis and untracked/binary exclusions.
Large counts wrap, never widen either detail surface. Text signs and
accessible descriptions keep meaning without color. User tint never recolors
additions or deletions. Missing current counts stay explicit text, not a
zero-valued badge. This presentation does not change collection. It does not establish the
agent's current working directory.
Only bounded aggregates cross into the sandbox. Paths and file contents do not.
Existing controller versions omit these optional fields. Refresh the native
integration explicitly to install the new controller. Existing supervisors and
sessions are not restarted or taken over to populate counts.

Nonblocking notices use a Design 06-inspired green, with a darker light-mode
variant. Blocked and failed states are red. Words and symbols distinguish attention from active work or
successful outcomes. Short IDs no longer lead outline rows. A row for exactly
one Copilot session leads with its **session name** (ADR 0022) and state; when
the name is unavailable, the CMUX surface title shows unchanged. The title is
never split on " - ". Managed rows keep their launch label, except a
born-managed root, which has none and uses its exact session's name; plain terminals,
browsers and other surfaces keep the CMUX title. Hover cards, details, the
Active window footer, Taskboard cards and Beat targets use the same name.
During observation loss a row keeps its last name for the grace period, but
the Active window footer shows only a live, confirmed session (otherwise the
CMUX title), for unmanaged and born-managed rows alike.
Exact session identity stays in details.

Agent icons come from the bundled **Nerd Fonts Symbols 3.5.1** font and its
pinned glyph-name catalog. No system font installation or uploaded images are
required. Catalog offers **10,994 drawable names**. Intentionally empty
`cod-blank` entry is excluded. Role favorites are presets, not the selection limit.
Ordinary terminal tabs use `md-ghost`. Browsers use `fa-edge` (U+F282).
**Sidebar settings → Agent icon** chooses the fallback robot or Copilot glyph for
sessions without explicit selection.

Click or right-click an **agent, terminal, or browser icon** to open its anchored
picker. Search all bundled glyph names (including role aliases), choose a color,
use **Done** or Escape to close. Keyboard: activate the icon button,
use Down from search and arrow keys in the grid, or Tab through controls.
**Show details** stays a separate action inside the popover. Opening the picker
and changing appearance do not focus a terminal, mark attention as read, or send input.
Provider-child observations and native agent surfaces without exact session
identity are not customizable. Other surface kinds keep standard icons.

**Your choice** wins over later agent metadata. **Reset to default** explicitly
chooses standard appearance. **Reset to agent selection** follows the
agent's current choice (or default when absent). Human preferences persist
by exact session UUID, or stable native surface UUID for non-agents, across restarts,
view changes and pane moves. They never transfer to a replacement session in the
same pane. Agent metadata stays separate and untouched. Sandbox stores these
bounded, coordinated preferences in its own Application Support
`CMUXMaestroPreview/sidebar-icons.json`. No additional filesystem or network grant
is required. Read/write failures are visible. **Sidebar settings > Reset all icon
preferences** is the explicit recovery action. Pets have their own picker (see
[Pets](#pets-cmux-maestro-nativemaestro-pet)). Favicon fetching is not part of
either picker.

`SidebarIconPicker` is a controlled, reusable SwiftUI view. Inject a
`SidebarGlyphCatalog`, `SidebarIconChoice`, source/notice text, and callbacks for
selection, resets and dismissal. `SidebarIconPickerButton` provides the native
primary/secondary-click and keyboard anchor. Neither component reads preferences,
knows session identity, or calls the host. `SidebarItemIcon` is the thin sidebar
adapter. It owns the popover and connects those components to persistence.
Picker uses inherited native appearance and semantic colors, with a neutral
catalog grid. Only an explicitly selected icon color and the swatches add color.
It does not hardcode themes. Automatic CMUX/Ghostty palette inheritance (for
example, switching between Nord and Tokyo Night) is tracked in
[#67](https://github.com/jdylanmc/cmux-maestro/issues/67). Pinned
sidebar SDK does not expose the host's resolved theme colors. Native light/dark
adaptation is not a claim of custom terminal-palette matching.

Only the workspace **name text** triggers its passive hover preview. Disclosure,
blank title fill, and actions do not. Leaving that text cancels or dismisses the
workspace hover immediately. Agent previews keep a 300 ms crossing grace.
Shared native card prefers the right edge, fits the available screen, and
scrolls long metadata. Hover waits 350 ms. Keyboard focus on a title previews it
without pressing it. **Tab** enters its preview controls, then continues past the
originating title after the last control. **Escape** or **Shift-Tab** returns to
that title. Next **Tab** continues onward, not back into the preview.
Explicit previews also close on outside
interaction. Workspace previews
show only current granted workspace metadata and shared-surface counts. Label denied
or ambiguous evidence unavailable. **Ports (CMUX, workspace-wide)** lists the port numbers
CMUX's `networkPorts` scope reports for the whole workspace, sorted and copyable, or
`None reported` (not proof that nothing listens) or `Not granted`. CMUX gives no owner,
address, protocol or completeness, so agent previews never show it.
Managed agent previews add one wrapping **Processes** field:
`PID 4242 (python3.12); PID 4243 (node)`, capped at 8 entries with trailing `+N`
overflow. Copy gives visible current PIDs, one per line, only for a complete,
current observation. Helpers stay counted separately; listeners keep their
endpoint rows ([background processes and ports](processes-and-ports.md)).

`SidebarHoverRegion` and `SidebarHoverCard` accept presentation data, independent
of sessions, navigation, preferences, and the bottom details. Passive panels
cannot become key/main windows. Only an explicit Preview action enables keyboard
interaction. Closing that preview restores its original responder when appropriate.
Right-click a row, use its transient overflow, or press **Shift-F10** on its title
for the same native grouped menu. Opening it is passive. **Preview details** is
also passive. **Open details** keeps the existing explicit mark-read behavior.
Overflow occupies a stable 24-point slot with a 2-point gap. Revealing it
never changes the title's width or truncation. Hidden controls are not keyboard stops.
Managed inspection requests retain the captured node, run, generation, session,
workspace and surface. A changed subject shows **Details no longer available**
without inspecting or marking the replacement read.
Icon-direct right-click still opens the compact icon picker, not the row menu.
Menu icon requests keep their exact identity. A replacement target shows
**Icon target changed**, never applies the old request to a new session.
Preview Close/Copy controls have an explicit native Tab order, independent of
system-wide keyboard-navigation preferences.
Hosted keyboard regression uses the production sidebar's automatically
constructed row key loop, including any intervening native controls. It requires
an unlocked graphical login so its
test-created windows can actually exchange key focus. It does not substitute
simulated key ownership when WindowServer denies focus.
AppKit rendering/interaction cases and the validation-host no-window assertion
share a test-only asynchronous gate across suites, held through fixture cleanup.
Other tests stay parallel. Motion captures fix and assert the logical viewport
before comparing exact native pixels. Static controls keep a zero-change requirement.
Activity-only children offer **Open parent chat**, never an independent surface.
**Choose pet…** opens the pet picker for an exact agent session. Unsupported pet
(activity-only children, status-only sessions), tag, backlog, placement and exit
actions show disabled reasons.
Menus add no capability or lifecycle authority.
Previewing never changes the **Active window** footer. Footer follows only the
current window's selected workspace and uniquely focused native surface.
Disconnected, redacted, missing or ambiguous focus clears the previous subject.
Ordinary terminals and browsers show native context without agent fields or a pet.
An agent on a terminal requires one fresh, live, exact observed session. Managed
labels and Git context additionally require current, uniquely bound managed
evidence. Positively ended observations do not compete with a replacement live
session. Unknown or ambiguous owners still prevent a unique current identity.
Reused surfaces, stale membership and matching titles never establish
ownership. Existing observation expiry updates the footer without a new timer.

Flush footer uses native adaptive colors. It shows the verified agent's animated
Codex-format pet (bundled original Maestro robot head by default; see
[Pets](#pets-cmux-maestro-nativemaestro-pet)). Click it to open the pet picker. Ordinary
terminals and browsers show no pet. Metadata is bounded and scrollable. Verified
Git counts use the existing compact badge. Full paths stay in Details. Existing
session-ID copy control stays near identity. No context percentages, elapsed
durations, tags or lifecycle controls are added.
Steady connection success adds no label or row, leaving the footer lower while
preserving the host's 50-point clearance. Waiting, disconnection and navigation
errors or permission summaries stay visible.

Same preview is available on managed agent and observed session titles in
Hierarchy and Taskboard, and on non-task activity titles in Hierarchy. Internal tasks instead use passive
single-line names with complete accessibility labels and tooltips, not chat
navigation or identity previews. Each card resolves its own exact
subject and only current or explicitly last-known metadata. Label missing/expired
observations. Never replace them with invented model, context, timing or
Git metrics. Windowless children keep parent-session placement context.
Agent cards show that exact session's own pet, honoring its hidden state; child,
terminal, browser and workspace cards show none. Hovering never changes the
footer pet. Opening a card never invokes the existing inspection/mark-seen action. Icon
picker, title-to-focus action, and history controls keep their explicit semantics.

Agent previews put a **Copy session ID** button beside the exact session GUID.
Observed children label their inherited identity **Parent session ID** and copy
that parent GUID, never the child/worker/run/surface ID. Missing, ambiguous, or
unavailable session identity has no copy action. Open **Preview** for keyboard
access. Hovering, opening, and refreshing never write to the clipboard.
A stale managed observation still offers its exact recorded session ID with
the existing last-known notice. Copying does not imply the session is live.
Every labelled detail (session ID, model, observed time, child history, paths) has a small
copy icon beside its label, always visible and dimmed until hovered or focused, in the pinned
footer and the preview. Successful copy swaps the icon for a checkmark and announces
**Copied** to VoiceOver, with no visible text. Failure shows **Could not copy. Try again.**
Changing the GUID clears feedback.
Small `SidebarCopyableValue` control receives an injected action. It knows
nothing about session lookup, persistence, host navigation, or the pasteboard.

Working agents use one 9-point open ring, rotating linearly once per second.
Reduce Motion keeps the ring static. Questions and approval requests use a
distinct static exclamation mark. Working rows have no shimmer or moving wash.
Blocked rows keep a subtle static red background. Idle/unknown rows do not
pulse or glow. State cues belong to their exact row, never its descendants.
The selected workspace's uniquely focused surface has a glowing left border,
separate from activity and icon color. Other workspaces' remembered focus does
not light a border. Ambiguous/unavailable focus evidence does not guess.
Identity colors do not change this treatment. Icons have no wand decoration.
Choosing an icon or role preset does not imply orchestration ownership.
Interactive agent rows (managed agents and single-session Copilot surfaces) are one
line: icon, name, tag chips (#51), state cue. No subtitle, location or activity
caption: 30-point Compact, 34-point Comfortable rows (ADR 0028). Their state, assigned
directory and activity stay in the row's help; the assigned directory also in hover and details. Other
surfaces keep a single-line name and one quiet metadata line: 11/9-point
type in 46-point Compact rows, 12/10-point type in 52-point Comfortable rows.
Missing context adds no placeholder or separator. Ordinary Terminal/Browser
labels, full location help and keyboard-accessible agent previews stay unchanged.
Routine Unknown, State unavailable and Last verified prose moves to full help,
accessibility and details, not a third row. Unknown/stale states keep a static
dashed cue, never an idle or working claim. Incomplete child-history context
shares that row's exact state cue instead of a redundant trailing info icon.
Protected attention and actual errors stay visible. Coordinator
activity comes only from a fresh, unique, live Copilot observation on its exact
workspace/surface. Registration or child activity alone cannot start a pulse.
**Sidebar settings → Terminal icon** offers Ghost and plain `>_` styles.
Workspace summaries are action-only: questions/approval requests show **needs
input**, other explicit blockers show **blocked**. Quiet workspaces show no
summary line. Top alert count uses the same rules. Routine turn completions
do not inflate it. Managed and observed representations on the same exact
workspace/surface count once. Collapsed descendants still contribute.
Last-reported managed blockers stay visible, with freshness qualified in help.
Agent totals, idle counts and repeated completeness warnings are not primary UI.
Source diagnostics stay in details. Glyphs have 2 pt insets in their existing
24 pt slots.
Standalone state keys keep pause/check/error symbols for blocked, finished and
failed states. Workspace headers have a boxed disclosure.
Their trailing ellipsis menu offers Focus, Expand/Collapse and Details as separate
actions. The four header shortcuts are directory-plus, Beats, Taskboard and Maestro
settings, in that order. Directory-plus opens a folder picker and asks
CMUX to create a workspace there (requires the workspace-creation action grants). Settings holds the sidebar
preferences, including the completed-work history controls.
Taskboard temporarily toggles the existing sidebar view (its underline and
accessible state indicate selection). Activate it again to return to the outline.
A workspace's menu has **Rename… (⇧⌘R)** and its preview ends with "⇧⌘R to rename": the
CMUX extension SDK has no rename action, so Maestro selects the workspace and reminds you of
CMUX's own ⇧⌘R shortcut.

## Projections

Workspaces are always the top level. One segmented control under the header,
**Worktrees | Sub-agents**, applies to every workspace in every window and is saved
(`sidebar.projection`, default Sub-agents) (ADR 0028). Switching changes presentation
only: nothing is focused, moved, acknowledged or adopted.

- **Sub-agents**: agents by recorded spawning parent, as before. A collapsed parent
  shows an icon card of every spawned descendant instead of a count.
- **Worktrees**: each workspace's agents grouped by their exact session's current
  worktree (ADR 0027): most recent verified tool touch this turn, last-known touch,
  then selected-directory fallback. Header: branch glyph, repository name, `branch · tree` or
  `Detached HEAD · commit · tree` (tree = first 7 hex of the opaque key), agent count.
  When members' observations report different heads, the second line shows only `tree`.
  Groups order: current worktrees (by repository, branch, key), last-known worktrees
  (clock glyph), `No repository`, `Unknown`. A child never takes its parent's
  worktree; an agent with no evidence, a non-current non-repository result, or no
  recorded session is `Unknown`. Same repository and branch in two worktrees are two
  groups. Plain terminals and browsers follow the groups.

- A collapsed group or parent is an **icon card**: each agent's state cue and icon in
  one row that scrolls inside the card, plus a separate expand control. Each icon
  focuses its agent's surface and previews like its row. Group disclosure is saved
  per workspace and group (`worktreeGroup` in the layout record), expanded by default.
  Meaningful state overlays the icon's corner; idle and finished icons have no badge.
  Outstanding attention and incomplete child evidence stay visible, including together
  with activity. Working badges honor Reduce Motion. Icons use equal 28-point targets
  with 4-point gaps, centered with the chevron. A collapsed parent's card starts at
  its title edge. Retained task activity and uncertainty stay inside the card, never
  in a separate summary row beneath it; counts remain in help and accessibility.
  Card attention follows expanded rows: turn-finished notices and recovered errors
  while working add no badge; permission and answer requests use the needs-input
  question glyph. The parent row already shows its own working state, so only
  hidden work contributes to the card's working count.
- Internal tasks stay subordinate text rows under their exact owner in both views.

Pinned details show labels and values only, not identity/binding explanation paragraphs.
Unconfirmed identity still withholds agent fields; unavailable managed metadata still falls
back to the exact observed session. The details inspector retains its own stale notices.
