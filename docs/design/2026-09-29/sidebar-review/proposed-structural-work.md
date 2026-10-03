# Proposal-to-ticket disposition - 2026-09-30

**All previously proposed work now has a GitHub ticket owner.** The focused
pass checked the entire 55-open-issue backlog and current discussion, all
87 issue identities, relevant delivered/superseded records and open PRs
#125/#129. It enriched **19 existing tickets** and created only **three**.
No nine-ticket research layer, duplicate collector or new umbrella was added.

| Proposal | Current owner / disposition |
| --- | --- |
| G1: preview/focus correctness | [#112](https://github.com/jdylanmc/cmux-maestro/issues/112) owns R1-R3; [#131](https://github.com/jdylanmc/cmux-maestro/issues/131) owns R4. No duplicate preview-repair issue. |
| G2: menu containment | New [#132](https://github.com/jdylanmc/cmux-maestro/issues/132), under #106; closed #43 stays closed. |
| G3: History/detail disclosure | New [#133](https://github.com/jdylanmc/cmux-maestro/issues/133), under #105; design decision first, no retention changes. |
| G4: repeated-prefix identity | Existing [#58](https://github.com/jdylanmc/cmux-maestro/issues/58) gains an explicit design gate; `needs-info` until decided. |
| G5 / P6: Beats contract | [#93](https://github.com/jdylanmc/cmux-maestro/issues/93) gets an in-ticket contract gate; no parallel scheduler/research task. |
| G6 / P7: utility hosting | [#86](https://github.com/jdylanmc/cmux-maestro/issues/86) owns route, reuse, restoration and draft decisions. |
| G7 / P8: worktree provenance | [#59](https://github.com/jdylanmc/cmux-maestro/issues/59) owns the evidence/key-lifetime gate; #73/#58 consume it. |
| G8 / P9: process/listener/context | [#78](https://github.com/jdylanmc/cmux-maestro/issues/78) owns shared process evidence for [#75](https://github.com/jdylanmc/cmux-maestro/issues/75); [#79](https://github.com/jdylanmc/cmux-maestro/issues/79) separately owns context evidence. |
| G9: remaining host seams | Feature-local gates in [#44](https://github.com/jdylanmc/cmux-maestro/issues/44), [#67](https://github.com/jdylanmc/cmux-maestro/issues/67), [#70](https://github.com/jdylanmc/cmux-maestro/issues/70), [#83](https://github.com/jdylanmc/cmux-maestro/issues/83), [#85](https://github.com/jdylanmc/cmux-maestro/issues/85); reuse #110 without widening it. |
| Evidence publication | New [#134](https://github.com/jdylanmc/cmux-maestro/issues/134), directly under #57. Artifact access/publication permission remain explicit inputs. |
| P1: #48/#131 overlap | #131 is the sole new internal-task implementation. [#48](https://github.com/jdylanmc/cmux-maestro/issues/48) owns report/safeguard reconciliation before any superseded-closure recommendation; no second ghost/timer renderer. |
| P2: missing epic relationship | Existing #131 is now a native child of #101 / #57. |
| P3: indicator delivery acceptance | [#111](https://github.com/jdylanmc/cmux-maestro/issues/111) retains its explicit gate-to-evidence/closure decision, not another masking implementation. |
| P4: details parent | [#105](https://github.com/jdylanmc/cmux-maestro/issues/105) remains non-dispatch tracking with focused new child #133; delivered containers are not reopened. |
| P5: runtime prerequisite | #61 and its #57 blocker remain unchanged; no disruption to #129 or runtime ownership. |

The three new leaves and #131's attachment were reread from GitHub.
All **87 existing issues' protected metadata** and **55 existing dependency
sets** were verified unchanged. Only the four intended parent links were added.
[Machine-readable audit](backlog-enrichment-20260930.json) records the coverage
and receipts.

This completes ticket capture, not implementation or design decisions.
#119/H8, unresolved source/product gates and the evidence-publication task
remain explicit. No existing issue was closed, reassigned or automatically
dispatched; no POC/native implementation or Git publication was performed.

<details>
<summary>Original September 29 proposal record (superseded by the dispositions above)</summary>

These decisions are separated from the authorized non-destructive issue/body
and readiness cleanup. **No new issues, closures, merges, reparenting, dependency
rewrites or Git publication have been performed by these proposals.**

The identifiers below are local proposal IDs, not invented GitHub issue numbers.
Existing issue ownership and #119's hardening-first/H8 gate remain in force.

## Existing-ticket disposition

| Proposal | Action to approve | Reason and preservation condition |
| --- | --- | --- |
| P1 | Consolidate #48 into #131, then close #48 as superseded if its remaining safeguards are fully covered. | The original internal-child report's ghost glyph and timer direction are superseded. #131 now owns task distinction, state relevance and exact outcome dismissal. Preserve the original evidence, incomplete-history, ancestry/attention and no-session-close safeguards; do not run two competing implementations. |
| P2 | Attach #131 under #101 / epic #57. | It is approved related visual work but currently has no native parent in the epic tree. This is an attachment proposal, not an existing relationship. |
| P3 | Reconcile #111's six original gates and close as delivered only if all required evidence exists. | PR #117 is merged, with related continuity/reader/identity work also merged. Starting the same masking implementation again is wasteful; merge status alone is not full native acceptance. |
| P4 | Decide #105's parent disposition. | #46/#52/#88 are all closed. Close the delivered aggregation after its integration evidence, or keep it only with a newly approved focused follow-up such as G1. Do not reopen its completed children or dispatch the parent as another implementation. |
| P5 | Move #61's hierarchy to the owning runtime/hardening track if desired, while preserving #57's blocker. | It is a real startup prerequisite, not a cosmetic deliverable. Keep current owners, open PR #129 and all runtime evidence; do not remove the safety gate merely to simplify the visual tree. |
| P6 | Split contract discovery from #93's implementation. | #93 still lacks selected CMUX-bound clock/store/control/repair contracts. G5 below would establish those inputs; #93 must remain a coherent runtime delivery with baseline end/recovery safety, not an unsafe partial scheduler. |
| P7 | Split #86's hosting decision from its implementation. | G6 below would produce the accepted host/reuse/restoration/draft contract. UI mockups cannot make unsupported content hosting ready. |
| P8 | Establish #59's worktree evidence contract before producer/consumer implementation. | G7 below makes the missing source/key-lifetime/provenance work explicit. Do not silently use Surface directory as verified agent cwd. |
| P9 | Share owned-process source discovery between #78 and #75. | G8 establishes one ownership/generation foundation. Keep process inspection and endpoint inspection as distinct deliveries; do not merge their UI/features or invent a finished dependency without the contract. |

Do **not** merge unrelated leaves merely because they share a container:
#73-80 retain distinct evidence contracts; #49/#50/#51 retain distinct ownership;
#94 and #95 do not acquire an ordering between each other. Do not revive the
already superseded #96/#97/#98 provider-exit split.

## Missing bounded work packets

### G1 - Repair reference-preview subject and keyboard continuity

- **Suggested parent:** #105, coordinated with #112 and #131.
- **Type:** POC/reference correctness; native acceptance additions are tracked
  in existing owners, not assumed native bugs.
- **Source:** review R1-R4 and screenshot observations S53-S56.
- **Outcome:** switching subjects starts at the new identity; pointer movement
  cannot remove a keyboard-focused preview; dialogs and filtered-outcome
  dismissal return focus to visible exact-context controls.
- **Acceptance:** reproduce all four failures, preserve active tab/ownership,
  retain same-subject scroll where appropriate, handle replaced/filtered
  origins, and preserve explicit Escape and raw clipboard semantics.
- **Verification:** isolated pointer/keyboard counterexamples plus existing
  copy/task/icon-card regression suites; no shared clipboard or live sessions.
- **Readiness:** bounded agent work after source access is supplied. Fix the
  working reference; never overwrite the immutable approved archive.

### G2 - Contain long-content row action menus

- **Suggested parent:** #106; follow-up to closed #43, not reopening it.
- **Outcome:** long identities never force horizontal menu scrolling or obscure
  available actions. Preserve the existing capability/action matrix and
  submenu support; do not invent new grouping or lifecycle controls.
- **Acceptance:** bounded readable title/metadata, vertical overflow where
  needed, no horizontal overflow, keyboard first/last/action/Escape paths,
  visible unavailable reasons and exact-origin restoration.
- **Verification:** paragraph names and 432-character unbroken identifiers at
  narrow/short sizes; test current native behavior before alleging a native
  regression. Repair the POC reference separately if needed.
- **Readiness:** well-bounded after the follow-up is approved; no new host
  capability or destructive operation belongs here.

### G3 - Decide bounded History/detail presentation

- **Suggested owner:** #57/#105 with #48/#131 visibility contracts preserved.
- **Outcome:** History and long diagnostic values are scannable without losing
  permitted raw values, failure/attention or outcome identity.
- **Evidence:** S27/S48-S51 and measured multi-viewport density/History overflow.
- **Required decision:** review a concise row/summary plus explicit expansion
  treatment before implementation. Do not invent another retained-record store,
  retention timer or session-management feature.
- **Acceptance:** no horizontal History overflow, reachable actions and focus,
  stable exact outcomes, raw-value access, and clear distinction between
  visibility dismissal and actual terminal closure.
- **Readiness:** design decision needed; not an implementation-ready ticket yet.

### G4 - Decide visible disambiguation for repeated-prefix session names

- **Suggested owner:** #101/#58, coordinated with #87 and previews.
- **Outcome:** similarly named sessions remain distinguishable before
  activation without turning the sidebar into permanent verbose metadata.
- **Evidence:** 39 filtered / 48 native-view stress siblings truncate before
  their distinct suffix; exact identity routing itself remains intact.
- **Required decision:** choose a collision-aware title/context treatment or
  other approved affordance. Do not guess a task summary from transcripts,
  rename sessions automatically or use text as an ownership key.
- **Verification:** same-prefix and identical-title cases, long Unicode/unbroken
  names, narrow widths, movements and replacement; preserve full accessible
  names and exact targets.
- **Readiness:** product/visual decision needed before implementation.

### G5 - Establish the Beats runtime/store/management contract

- **Suggested parent:** #42, supplying #93 rather than replacing its policy.
- **Type:** bounded source/feasibility research, executable without live timers.
- **Deliverable:** version-pinned selected CMUX-lifetime clock/runtime location,
  one store, supported exact-self/human operations, cron dialect, human
  repair/first-enable/delete-choice surface and crash/uncertain-handoff seams.
- **Acceptance:** every choice maps to #42's already settled policy. Identify
  unsupported capability and minimal authorized change; do not reopen local
  time, retained definitions, paused relaunch or no-queue-management decisions.
- **Stop rule:** source gaps produce a specific blocked result or separately
  approved disposable experiment proposal, never a daemon or terminal fallback.
- **Readiness:** research packet can be made ready immediately on approval;
  #93 implementation stays gated until its inputs are accepted.

### G6 - Establish reusable utility-tab hosting

- **Suggested parent:** #104, supplying #86.
- **Deliverable:** a supported host/SDK route and explicit reuse scope, exact
  identity, saved/restored state, window/workspace lifetime, draft closure and
  move/refusal contract for Beats/Taskboard.
- **Acceptance:** distinguish source declarations from producer/consumer
  availability; preserve agents/schedules independently of view lifetime.
  Derive current pane-position labels or omit them.
- **Stop rule:** no new broker, raw sidebar socket, generic plugin framework,
  installation or live resource creation without separate approval.
- **Readiness:** source-only research can be scoped; implementation cannot be
  declared ready from the HTML pane simulation.

### G7 - Establish current worktree identity/provenance

- **Suggested parent:** #101, supplying #59/#73.
- **Deliverable:** accepted source semantics and opaque identity lifetime for
  current agent worktree, including rename/recreation, negative repository
  evidence, managed/unmanaged coverage and invalidation.
- **Acceptance:** explicitly reconcile PR #130/#77's Surface directory semantics.
  Neither launch assignment, terminal metadata, branch name nor parent identity
  is automatically current agent/tool cwd.
- **Verification:** version-pinned source matrix and bounded negative/identity
  cases; propose only a necessary separately authorized proof for gaps.
- **Readiness:** research-ready on approval; producer/consumer completion waits
  for the accepted contract.

### G8 - Establish owned-process/listener and context evidence

- **Suggested owner:** #100; use two independent research slices.
- **Process/listener slice:** one authoritative bounded ownership/generation
  source shared by #78/#75, including detached work, PID/port reuse, protocol
  uncertainty and privacy. No machine-wide attribution or raw commands.
- **Context slice:** version-pinned provider current-usage/capacity semantics
  for #79, including model change and compaction. Billed totals, marketing
  limits and transcript-derived estimates are not substitutes.
- **Acceptance:** each output names available/unsupported fields, producer,
  permissions, source freshness, failure behavior and exact consumer mapping.
- **Readiness:** source-only investigations are bounded; no implementation
  readiness until supported evidence exists.

### G9 - Audit the remaining host/SDK capability seams

- **Suggested owners:** existing #44/#67/#70/#83/#85 leaves.
- **Deliverable:** a small source-only matrix for native reorder operations,
  resolved semantic theme palette, navigation/favicon metadata, Keep Mac Awake
  read/write/updates, and directory/workspace creation.
- **Acceptance:** pin producer/transport/consumer revisions, minimum grants,
  result/notification semantics, and older-host fallback for each capability.
  Keep #110's existing pane-topology research separate rather than widening it.
- **Stop rule:** missing capability is explicit; no side-channel, settings
  scraper, broad grant, host update or live operation is authorized by research.
- **Readiness:** individual research slices can be agent-ready after approval;
  the existing feature tickets remain needs-info until their routes are chosen.

## Decisions that source research cannot make for the operator

1. #45: backlog URL destination (new CMUX browser surface or system browser).
2. #50: approved distributable pet assets/rights and any product-specific
   animation/status treatment beyond the original placeholders.
3. #85: duplicate-directory/partial-creation behavior if native prior art does
   not settle the requested semantics.
4. #86: reuse/restoration and unsaved-draft closure policy where multiple valid
   host routes remain.
5. G3/G4: density/disambiguation treatment.
6. Publication/structural authority for the proposals above, and #119/H8's
   separate explicit acceptance before cosmetic-only dispatch.

The backlog can be made clear now; these facts cannot honestly be turned into
completed decisions by assigning `ready-for-agent` to every item.

</details>
