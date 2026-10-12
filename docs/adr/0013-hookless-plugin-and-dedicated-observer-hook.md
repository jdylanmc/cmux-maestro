# Hookless plugin plus a dedicated observer hook

The native plugin `cmux-maestro-native` ships without hooks. A dedicated version-1 file, `~/.copilot/hooks/cmux-maestro-observer.json`, declares `sessionStart`, `userPromptSubmitted`, and `postToolUse`. Setup supports stable Copilot CLI 1.x with protocol 3 only, preserves unrelated hooks, plugins, settings, and disabled-hook keys, and refuses when it cannot map disable state exactly.

Why: plugin hooks cannot be disabled or migrated per key safely. One owned file can be installed, verified, and removed without touching anyone else's.

Rejected: legacy plugin-hook registration, guessing disable hashes, enabling duplicates to read keys.

Consequence: some safe-looking migrations stay blocked. Cached hooks in running sessions need a restart.
