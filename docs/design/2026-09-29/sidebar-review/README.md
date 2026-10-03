# Sidebar design and interaction review

**Latest backlog follow-through (September 30):**
[proposal-to-ticket map](proposed-structural-work.md) and
[verified enrichment audit](backlog-enrichment-20260930.json).
All known G/P proposals have ticket owners: 19 existing tickets enriched,
only three new focused leaves (#132-134), and #131 attached to the visual epic.
This supersedes the proposal-only status and earlier readiness counts below,
not the immutable design evidence or review findings.

**Review scope:** the approved September 29 HTML POC, its complete integrated
source and all identified sidebar surfaces. This review does not revoke the
visual lock, repair its source, or claim native implementation/acceptance.

**Result:** the tab-versus-internal-task distinction and five active rapid-fire
refinements are coherent. Four additional interaction defects are reproduced.
Long-content menus/history, name ambiguity and content density remain gaps.
Legacy Beats/exit simulations must not be treated as current product policy.

**Backlog outcome:** [54-ticket reconciliation](backlog-review.md),
[verified per-ticket audit](backlog-audit.json), and
[structural/missing-work proposals](proposed-structural-work.md).
Forty-four existing GitHub briefs/readiness classifications were updated;
16 are specification-ready under existing gates, 14 retain explicit information
gaps, and four require human decisions. No blanket execution readiness is claimed.

## Evidence

- [Approved visual lock](../sidebar-refinement/README.md).
- Approved source-tree SHA-256:
  `cd2b10cb2355406c28b844199b0716a7c576de6161bc4cc836dc5096674b7158`.
- Frozen archive SHA-256:
  `4b54c765a550f3081fc88ccd57a6cbfa701d83bb59ee8e868ec122f3b5d8093a`.
- [Interactive screenshot gallery](gallery.html): **56 captured states**.
- [Capture matrix and observations](screenshots.json): source binding, captions,
  related tickets, explicit defect/legacy-policy classifications and hashes.
- Contact sheets: [1](contact-sheet-1.png), [2](contact-sheet-2.png),
  [3](contact-sheet-3.png), [4](contact-sheet-4.png).

Images are isolated-browser captures of synthetic data, not the operator's
private screenshots. Full image links in the gallery are the detailed evidence;
contact sheets are navigation aids. The captured POC source remained unchanged.

## Surface-by-surface breakdown

| Surface | Evidence | Assessment / backlog owner |
| --- | --- | --- |
| Header and global projections | S01-S06 | Clear separation of header actions and Worktrees/Sub-agents/Workspace. Native topology is not proven by the mock. #39/#58/#83-85. |
| Workspace identity, eye and preview | S07, S09, S26, S52 | Header stays bounded. Eye semantics for internal tasks are settled; inherited finished-chat filtering remains separate. Native incomplete counts and keyboard workspace-preview access still need their own evidence. #48/#52/#58/#88. |
| Internal task category and disclosure | S04, S08, S47 | Text-only subordinate activity, meaningful state marks, right-aligned status, independent collapse and protected summaries match intent. Dismissal focus fallback is R4. #131, with shared policy under #48. |
| Collapsed worktree icon cards | S45-S46 | All visible participants are in one locally scrolling row. No tags/grid/four-item truncation. RF-04 is superseded. #58/#51. |
| Pinned agent/browser/terminal details | S03, S12, S14 | Subject and capability remain distinct. Copyable raw values survive formatting. Long-record density is not solved by wrapping. #46/#73-80/#112. |
| Passive previews and copy | S10-S15, S48-S49, S53-S55 | Horizontal containment works. Subject-change scroll and keyboard focus continuity have defects R1-R3. #100/#105/#112. |
| Identity icons and pets | S16-S20 | Human override/reset concepts remain distinct. POC pets are original placeholders, not evidence of Codex artwork rights. Browser favicon sourcing is not demonstrated. #49/#50/#70. |
| Tags and colors | S21-S23 | Human versus agent ownership, validation and shared color overrides are explicit. Source-wide storage and agent authorization remain implementation obligations. No tags belong in collapsed icon cards. #51. |
| Row/workspace actions | S24-S26, S50 | Existing actions remain discoverable, but long-name menu containment is unresolved. Historical exit entries are not current requirements. #43/#45/#106. |
| History and cleanup | S27-S29, S51, S56 | History visibility, internal outcome dismissal and terminal closure are different concepts. The mock's old human-exit flow must not drive #60/#90/#91. History overload remains unresolved. #48/#60/#131. |
| Directory and Settings | S30-S35 | Entry, validation and four guide-status states are shown. Directory text entry and the Settings scenario selector are lab tools, not production chooser/probe proof. #55/#84/#85. |
| Fermata | S36 | Compact on/off presentation exists. The Boolean is synthetic, not host power-state synchronization. #83. |
| Beats and cron helper | S37-S40 | Composition is useful; UTC, one-pending/cancel-before-edit and old recovery assumptions are not current policy. #42/#93/#94 govern. |
| Utility hosting and Taskboard | S41-S43 | Views remain separate from sidebar projection. Host reuse/restoration is unproven; post-reorder Move labels are demonstrably stale. Taskboard density also needs bounded presentation. #86/#87. |
| Whole-sidebar overload | S44-S52 | 61 chats, 172 internal tasks, 65 real tabs, long identifiers and deep/wide trees exercise more than the short-name happy path. Fixed containment must not conceal unresolved density or identity ambiguity. |

## Consequential findings

All findings below are demonstrated in the **HTML reference**. They become
implementation acceptance cases; they are not automatically established native
bugs and must not reopen closed native work without reproduction.

### R1 - A new preview subject inherits the previous subject's scroll

- **Priority:** Important.
- **Confidence:** High; independently reproduced and confirmed by S53.
- **Location:** `prototype/app.js:620-638`, `showHover()`, at the approved source
  digest above; [S53](images/s53-preview-subject-scroll.png).
- **Evidence:** after scrolling `stress-root` to the bottom and previewing
  `stress-agent-3`, the new card retains `scrollTop = 5473`; its identity heading
  is at viewport Y = -5420. The active tab remains `stress-root`.
- **Consequence:** icon-card navigation opens another subject halfway through
  its data, concealing the identity that makes the preview understandable.
- **Standard:** approved independent hover subject and full accessible identity;
  preview navigation must not confuse subjects.
- **Recommended fix:** reset scroll on subject change, not indiscriminately on
  same-subject updates or strip scrolling.
- **Verification:** pointer and keyboard A-to-B preview transitions after
  scrolling A; B starts at its identity, contains B's raw values and does not
  change selection.
- **Routing:** shared preview follow-up under #105; avoid duplicating field
  collection under #100.

### R2 - Pointer departure removes a keyboard-focused copy action

- **Priority:** Important.
- **Confidence:** High; independently reproduced and confirmed by S54.
- **Location:** `prototype/app.js:870-878`, originating-row `pointerout`;
  [S54](images/s54-pointer-dismisses-keyboard-preview.png).
- **Evidence:** hover the reviewer row, keyboard-focus it, Tab into its copy
  action, then move the pointer into the stage. After the 220ms leave timer,
  the card hides and focus becomes `BODY`. With the pointer already outside
  the row, keyboard navigation survives.
- **Consequence:** incidental mouse movement interrupts keyboard copy/navigation.
- **Standard:** the preserved September 26 label/copy contract requires usable
  keyboard traversal and meaningful focus.
- **Recommended fix:** recheck current preview focus before delayed pointer
  dismissal, including when the timer fires; preserve explicit Escape.
- **Verification:** pointer-over-row entry followed by keyboard traversal and
  pointer departure; the focused preview action remains usable after 220ms.
- **Routing:** extend #112 acceptance; do not treat its existing happy-path
  keyboard checks as sufficient.

### R3 - Preview-originated dialogs lose their keyboard return target

- **Priority:** Important.
- **Confidence:** High; independent row/icon cases and S55 reproduction.
- **Location:** `prototype/app.js:613-643,934-938`, hover clearing and dialog
  focus restoration; [S55](images/s55-preview-dialog-return.png).
- **Evidence:** enter the reviewer's preview by keyboard, Tab through the six
  copy actions to its tag, open the color dialog, then Escape. Focus becomes
  `BODY`, not the visible originating row/icon. Selection stays unchanged.
- **Consequence:** users lose their place, particularly in a long icon card.
- **Standard:** preserved keyboard access, tag interactions and originating-row
  return behavior.
- **Recommended fix:** capture the visible exact origin before hiding the
  preview; restore it after cancellation/completion or resolve a visible
  replacement control after rerender.
- **Verification:** row and scrolled-icon origins, tag/color actions, cancel and
  completion, with exact identity and unchanged selection.
- **Routing:** #112/shared preview integration; a POC-only repair can be separate
  from native acceptance.

### R4 - Dismissing the final retained outcome loses sidebar focus

- **Priority:** Important.
- **Confidence:** High; independent reproduction and S56.
- **Location:** `prototype/app.js:328-332,761-774`, relevance filtering and
  outcome-dismiss focus restoration; [S56](images/s56-filtered-parent-dismissal.png).
- **Evidence:** a completed outcome retains the finished `researcher` row.
  Dismiss that last outcome with finished chats hidden: the projected parent
  disappears, focus becomes `BODY`, but its real tab remains open and no session
  is marked dismissed.
- **Consequence:** completing outcome review unexpectedly loses the user's place.
- **Standard:** outcome visibility is not tab/session lifetime; keyboard
  continuity must survive a permitted visibility change.
- **Recommended fix:** choose a deterministic visible adjacent/container control
  when the owner's projected row no longer exists, without changing selection.
- **Verification:** both visible-owner and filtered-owner dismissal; retain
  visible focus, real tabs, exact outcome identity and unchanged ownership.
- **Routing:** #131 and shared visibility acceptance in #48.

## Other demonstrated limits and policy mismatches

| Item | Evidence | Required disposition |
| --- | --- | --- |
| Stale utility position labels | S43 records pane order `[2,1]` but labels `Pane 1 - left`, `Pane 2 - right`. | Keep/finalize #86's existing requirement to derive current positions or omit spatial labels; no duplicate ticket. |
| Menu and History overflow | S50-S51; stress measurements exceed container widths. | Separate bounded follow-ups for menus and History; do not reopen #43 merely because the mock needs repair. |
| Repeated-prefix identities | Dozens of stress sessions truncate before their distinct suffix. | A display-disambiguation decision is still needed; preserve exact identity regardless of chosen appearance. |
| Detail and History density | S48-S51 show many viewport heights of raw long data. | Design progressive disclosure or bounded summaries without losing raw-value access; wrapping alone is not a scanability solution. |
| Legacy Beats semantics | S37-S40 still show old UTC/pending-queue assumptions. | #42's local-time, one-attempt-per-occurrence, no queue management and human recovery policy overrides the mock. |
| Legacy human exit controls | S24, S27-S29. | #60's framework-neutral PM cleanup governs. Human tab closure remains CMUX-owned; never recreate old provider-specific shutdown flows from these screenshots. |
| Additional diagnostic fields | POC does not implement authoritative ports, owned processes or context capacity. | Preserve #75/#78/#79. Absence from the mock is neither removal of scope nor evidence that sources exist. |

## Review coverage and limits

The parent inspected all four contact sheets, the primary full-resolution
refinement captures, the UI source/interaction routes and capture observations.
One independent reviewer inspected the integrated 17-file POC, its tests and
eight lock images, and ran fresh isolated counterexample probes. The parent
reproduced R1-R4 while generating the full matrix.

Requirements coverage includes tab/task distinction, state/identity rules,
disclosures, every primary row/preview/control category, normal/error/stress
states and unchanged-source verification. Existing suites and the independent
pass also cover 280/350/460px geometry, local icon-card scrolling, selection,
copy values, motion and persistence. This is not every possible event ordering.

Engineering-standards coverage used the active Roast reviewer contract and
required **solid** doctrine, loaded and hash-verified:
`1df4a6a27aae555ad1bfc058a0749bf8a58e73afdcd109e46ca1ae2293ec69e6`.
No supported structural SOLID finding justified adding abstractions to this
synthetic mock. Archived skill validators/hooks were not run.

No native app/host/provider acceptance, installation, live scheduling, current
session manipulation, VoiceOver validation, or arbitrary custom-theme proof
was performed. Read-only native-source checks for backlog grounding use main
`5a8ec0eb65bbee3a4685ae07daeb1b7e86a7047d`, separately from the HTML snapshot.
The native SDK pin remains `ae7fbce99f98c98df5ccf915e548dd080d33cfa8`;
existing host/capability gates must not be replaced by synthetic screenshots.
