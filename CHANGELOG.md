# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Versioned September 25 visual-design reference, reproducible browser
  prototype, focused screenshots, and visual-backlog audit for #57. This
  documents the approved target; it does not ship native behavior.

### Changed

- Commit project-local skill files, references, helpers, and upstream notices
  alongside the lockfile so a checkout includes the reviewed skill set.
- Standardize repository agents on upstream CMUX and refreshed personal skills,
  excluding the Orca coordinator.
- Use all open GitHub Issues in `jdylanmc/cmux-maestro` as the default backlog,
  with explicit issue or epic narrowing.

### Fixed

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
