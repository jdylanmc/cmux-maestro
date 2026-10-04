# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Request one exact owned child-terminal close through stock CMUX, preserving
  private ownership and launch guards. Return request acceptance without waiting
  for removal, retrying, shutting down the provider, or releasing capacity; inherit
  CMUX's socket confirmation bypass and last-terminal refusal (#90).
- Versioned visual-design references for #57, including the frozen September
  29 prototype, approved contract, 56-state synthetic review gallery and
  current ticket handoff (#134). Preserve earlier evidence and distinguish
  the approved target from native delivery and current feature readiness.

### Changed

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
  timing or test deadlines.
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
  surviving tab, and keep moved terminals counted against the eight-resource
  limit using atomic host inventory (#64).
