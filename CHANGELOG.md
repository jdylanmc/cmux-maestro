# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Added

- Show separate read-only Maestro guide status for the current Copilot and legacy
  install locations in CLI Integration settings, with build-bound content checks,
  explicit errors, and a manual install/update command that leaves live sessions
  and global configuration untouched (#55).

### Fixed

- Preserve managed-session custody through failed startup and partial storage
  publication; allow safe failed or exited managed roots to archive without a
  surviving tab, and keep moved terminals counted against the eight-resource
  limit using atomic host inventory (#64).
