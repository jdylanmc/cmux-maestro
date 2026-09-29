# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Versioned September 25 visual-design reference, reproducible browser
  prototype, focused screenshots, and visual-backlog audit for #57. This
  documents the approved target; it does not ship native behavior.

### Changed

- Manage Copilot CLI 1.0.88 and 1.0.89 observers in a dedicated user-hook file through
  explicit setup, with verified migration/removal and truthful disabled or
  incomplete status. Unsafe ownership and unresolved per-hook disables refuse
  migration without changing the existing registration; existing sessions are
  not restarted or reloaded (#114).
- Commit project-local skill files, references, helpers, and upstream notices
  alongside the lockfile so a checkout includes the reviewed skill set.
- Standardize repository agents on upstream CMUX and refreshed personal skills,
  excluding the Orca coordinator.
- Use all open GitHub Issues in `jdylanmc/cmux-maestro` as the default backlog,
  with explicit issue or epic narrowing.

### Fixed

- Start setup-test fixture readiness after installer spawn rather than task
  enqueue, preserving timeout, cancellation and process-cleanup checks.
- Wait for a visible, settled native viewport before measuring offscreen focus
  layout, preserving exact frame and width invariants.
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
