# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Versioned September 25 visual-design reference, reproducible browser
  prototype, focused screenshots, and visual-backlog audit for #57. This
  documents the approved target; it does not ship native behavior.

### Fixed

- Preserve managed-session custody through failed startup and partial storage
  publication; allow safe failed or exited managed roots to archive without a
  surviving tab, and keep moved terminals counted against the eight-resource
  limit using atomic host inventory (#64).
