# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Versioned September 25 visual-design reference, reproducible browser
  prototype, focused screenshots, and visual-backlog audit for #57. This
  documents the approved target; it does not ship native behavior.

### Changed

- Standardize repository agents on upstream CMUX and refreshed personal skills,
  excluding the Orca coordinator.
- Use all open GitHub Issues in `jdylanmc/cmux-maestro` as the default backlog,
  with explicit issue or epic narrowing.

### Fixed

- Preserve managed-session custody through failed startup and partial storage
  publication; allow safe failed or exited managed roots to archive without a
  surviving tab, and keep moved terminals counted against the eight-resource
  limit using atomic host inventory (#64).
