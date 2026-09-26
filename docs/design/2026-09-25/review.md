# Independent design review

**Reviewer:** independent general-purpose review agent
`03b3c421-4106-472d-a461-012d49f004af`, separate from the prototype implementer.
**Date:** 2026-09-25 local / 2026-09-26 UTC.
**Comparison:** the full frozen browser design and 28 captures over repository
base `2827bc95b22787b4c504d060a81801c561c57493`, not a native-code change.

All captured image digests and the served HTML/JavaScript/CSS were checked
against the frozen local bytes. The reviewer used an isolated browser context,
not the user's live CMUX or prototype tab. No source or GitHub writes, new
dependencies, native installation or actual agent scheduling occurred.

## Findings and disposition

### Important: incomplete keyboard preview access

- **Location:** workspace-name preview, collapsed-summary agent buttons and
  interactive controls in agent hover cards. See
  [workspace hover](images/workspace-hover.png),
  [worktrees](images/worktrees.png), and
  [agent hover](images/agent-hover.png).
- **Observed:** keyboard focus on the workspace-name button or a collapsed
  participant did not open a preview. Expanded-row main-button focus opened
  one without changing the pinned agent, but Tab proceeded to overflow/other
  row controls and closed it before reaching its tag actions.
- **Consequence:** pointer and keyboard access are not equivalent. The mock
  cannot substantiate a blanket keyboard-accessibility claim.
- **Confidence:** high for the reproduced browser behavior; VoiceOver untested.
- **Standard:** the human's accessible-preview and independent pinned-subject
  requirements; documentation doctrine's "Treat disagreement as drift."
- **Direction:** support name/summary focus previews and an explicit keyboard
  traversal/return path, without reintroducing the information button or
  triggering preview from workspace action buttons.
- **Verification:** traverse each entry and its available preview actions by
  keyboard; Escape returns to origin; active/pinned identity stays unchanged;
  negative hover checks still exclude eye/backlog/menu/collapse.
- **Disposition:** retained as a documented prototype exception. Updated
  acceptance in #43/#46/#58 and workspace-hover follow-up #88 owns resolution.

### Important: stale spatial labels in utility Move

- **Location:** [utility Move dialog](images/utility-move.png), after reordering
  panes in Workspace projection.
- **Observed:** moving Pane 1 down yields Pane 2 on the left and Pane 1 on the
  right in the sidebar/layout. The dialog still says "Pane 1 - left" and
  "Pane 2 - right."
- **Consequence:** choosing by position can select the opposite split. Stable
  pane identity is confused with mutable position.
- **Confidence:** high.
- **Standard:** human-approved pane reordering and explicit destination
  selection; documentation doctrine's "One concern, one authority."
- **Direction:** derive spatial descriptions from current destination-workspace
  order, or identify panes without left/right descriptions.
- **Verification:** reorder panes, then move both utility views to every
  destination; repeat across workspaces with different orders; preserve agent
  identity and Beat definitions.
- **Disposition:** retained as a documented prototype exception. The new
  utility-tab hosting issue #86 explicitly requires correct destination labels.

## Coverage

The reviewer visually inspected all 28 supplied captures and exercised header
order/accessibility names, workspace eyes and hover exclusions, reduced-motion
status, eight-level density, tag ownership/color overrides, all five sibling
reorder unit types, pointer rejection, Beats queue deduplication, cron helper,
utility tab reuse/move/close, settings, directory simulation, Fermata and pet
preference independence.

Fourteen tag swatches and 10,000 generated slugs were sampled with minimum
observed text contrast of 4.795:1. This is sampled browser evidence, not native
system-wide enforcement.

The reviewer loaded and verified the documentation doctrine at SHA-256
`54a88537818b03546edc460fc29988141e500a37a2c604f718ea15051af11040`,
applying "One concern, one authority," "Document what code cannot," and "Treat
disagreement as drift." This was a product-design/interaction review, not a
SOLID/code-architecture audit.

## Documentation follow-up

The same independent reviewer then checked the completed design README,
review report, issue audit, issue-tracker paragraph and changelog against the
frozen source, evidence and relevant publication-plan criteria. The result was
**no additional supported findings**.

Both important interaction defects remained explicit non-approved acceptance
exceptions. The reviewer confirmed that the prose retained experiment-only
boundaries, unsettled production policies, omitted field requirements,
completed issues and unchanged Joe dispatch scope.

That follow-up did not inspect eventual GitHub issue bodies or final numeric
references. Those publication results were verified separately against the
approved write plan; the underlying prototype and capture bytes did not change.

## Limits

No native CMUX integration, actual scheduler/process behavior, VoiceOver,
all-platform accessibility certification, exhaustive viewport coverage or
asset-redistribution rights were established. The originally supplied review
material did not yet include the completed lock-document prose. Any later
documentation follow-up is recorded separately rather than recast as part of
this initial review.

Native field issues #73-81 keep their unrepresented requirements; closed
#49/#52/#76 keep their delivery status. Defaults that remove artificial edge
cases do not waive real missing/stale/failed evidence handling. UTC, queued
pause/edit policy, system-wide tag storage, host settings routing and real
Fermata state remain explicitly bounded in the design lock.
