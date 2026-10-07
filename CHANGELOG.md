# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Request optional per-launch model, context tier and reasoning effort using
  bounded session-scoped capability evidence, with visible configured fallback
  for unsupported preferences and refusal of unsafe or foreign evidence.
  Configured arguments remain distinct from observed provider settings (#154).
- Configure per-workspace launch capacity from 1 to 128 (default 32) through
  an authenticated coordinator CLI, with advisory usage/preflight and exact
  root, worker, retained-resource and pending-lease accounting. Preserve
  existing lock budgets and independent node/depth bounds (#154).
- Request one exact owned child-terminal close through stock CMUX, preserving
  private ownership and launch guards. Return request acceptance without waiting
  for removal, retrying, shutting down the provider, or releasing capacity; inherit
  CMUX's socket confirmation bypass and last-terminal refusal (#90).
- Versioned visual-design references for #57, including the frozen September
  29 prototype, approved contract, 56-state synthetic review gallery and
  current ticket handoff (#134). Preserve earlier evidence and distinguish
  the approved target from native delivery and current feature readiness.
- Add label-owned copy actions for permitted raw session, observation,
  child-history and path values in agent previews and pinned details,
  preserving provenance, keyboard access and explicit clipboard feedback
  (#112).

### Changed

- Inherit explicit recorded parent launch permissions for prospective native
  children, preserving denies, narrowing and provenance/drift refusals. Current
  provider-policy equivalence and actual restricted startup remain unverified
  (#154).
- Raise the default per-workspace limit from 8 to 32 live managed sessions,
  including managed coordinators and retained resources, without changing
  launch accounting or the 128-node and eight-level nesting limits. Validate
  immutable read snapshots outside the shared lock so readers do not block
  writers during decoding and validation, and share read-only runtime ticket
  lookups. Scale bounded lock-acquisition budgets against the fixed 32-session reference,
  retaining exclusive mutations, failure on exhaustion and launch/result deadlines.
- Attempt Copilot integration with stable CLI 1.x releases on protocol 3 instead
  of an exact-release whitelist. Preserve source ownership, disabled-state
  readback and transaction guards; report incompatible version/protocol pairs.

- Constrain the working long-identity action-menu reference to the viewport,
  preserving complete accessible names and keyboard-reachable actions (#132).
- Guide native Maestro coordinators and workers to send compact milestone-only
  handoffs, yield between decisions, and reconcile current-candidate evidence
  without losing unresolved findings. Preserve fire-and-forget messaging and
  independent delivery gates (#142).
- Match internal-task headings to the approved prototype without inline
  completeness diagnostics, preserving counts, task visibility and detail hints.
- Show internal Copilot tasks as compact, non-interactive lines with
  workspace-local visibility, persistent disclosure, and exact-outcome
  dismissal that preserves local keyboard focus (#131).
- Coordinate updates to the recognized Maestro app and its Copilot CLI
  1.0.88/1.0.89 integration, verify identical reinstalls, and recover prior owned
  state after failed or interrupted publication. Bind ownership through public
  provider results, restore supported disable choices before publication, and
  preserve unrelated plugins. Gracefully restore the exact containing app
  without activation; do not restart existing Copilot sessions. Retain one
  inactive app for recovery, and report conflicting native registrations before
  changing the installed app. Registration status describes owned state, not
  provider-wide uniqueness or loaded-session behavior (#114).
- Route live Copilot observations through the existing provider-neutral session
  snapshot, preserving lifecycle/liveness distinctions, partial ancestry,
  history and attention behavior. Retain v1 decoding and nested validation,
  checking neutral evidence before history filtering without adding control
  capabilities (#10).
- Commit project-local skill files, references, helpers, and upstream notices
  alongside the lockfile so a checkout includes the reviewed skill set.
- Standardize repository agents on upstream CMUX and refreshed personal skills,
  excluding the Orca coordinator.
- Use all open GitHub Issues in `jdylanmc/cmux-maestro` as the default backlog,
  with explicit issue or epic narrowing.

### Fixed

- Keep valid provider-native reasoning defaults from blocking unrelated model
  selection; omit unrepresentable CLI defaults while retaining malformed-data
  refusal and warned provider-default behavior (#154).
- Allow bounded finite child narrowing from recorded YOLO without redundant
  parent allow rules, preserving denies, default-parent and escalation guards
  (#154).
- Clean up failed orchestration-test fixture registration through the existing
  quiescence protocol, retaining evidence and both errors when cleanup cannot
  complete (#154).
- Qualify managed Git labels, verification and change counts as evidence from
  the assigned directory, not Copilot's current `/cwd`, preserving stale and
  unavailable states and separate CMUX surface-directory reports (#119, #59).
- Keep exact-chat visual status through temporary observation gaps for five
  minutes, then quietly show Status unavailable without retaining control
  authority; preserve real background tabs and internal-task parents (#119).
- Start managed Copilot terminals directly with verbatim Maestro-wrapped tasks,
  return acceptance without a startup wait, and derive activity from fresh exact
  session observations. Preserve messaging across normal extension reloads and
  retain uncertain launch ownership without retries or guessed cleanup (#61).
- Qualify agent and child directories as CMUX surface or parent-surface reports,
  with explicit source and report-age limits, preserving exact placement, path
  permissions and home-relative display (#77).
- Start setup-test fixture readiness after installer spawn rather than task
  enqueue, preserving timeout, cancellation and process-cleanup checks.
- Stabilize offscreen focus-layout fixtures with owned overlay/legacy-equivalent
  content widths, retaining real-native scroller coverage and detection of
  genuine geometry changes (#127). Sample applied native style transitions
  before later recommendations, isolate cross-process observation from AppKit
  rendering, and control lifecycle-fixture clocks without changing production
  timing or test deadlines. Capture bounded metadata-test stall diagnostics
  without masking failures or claiming the underlying hang is repaired.
- Automatically omit unneeded old managed registrations when an exact current
  replacement is verified. Preserve ancestors and original-session context
  needed by work or unresolved attention, without deleting records or closing
  terminals and sessions.
- Keep a replacement session's working or idle status visible when ended agents
  are shown, without duplicating retained managed identities or hiding their
  descendants and attention (#111).
- Keep Copilot session observation current across valid oversized tool, message,
  model and asset payloads, including metadata maps, using bounded metadata-only
  projection with exact completion attribution and explicit degradation for
  malformed history (#121).
- Preserve observed child names, kinds and ancestry on explicitly configured
  Copilot multi-turn continuations, without letting old spawn outcomes finish
  the new interaction. Match observed message interaction/turn metadata to
  restore Idle after interleaved follow-up completion; missing or contradictory
  proof still reports Unknown. This fixes demonstrated continuation behavior,
  not every Unknown agent or all of #118.
- Preserve managed-session custody through failed startup and partial storage
  publication; allow safe failed or exited managed roots to archive without a
  surviving tab, and keep moved terminals counted against the live-resource
  limit using atomic host inventory (#64).
