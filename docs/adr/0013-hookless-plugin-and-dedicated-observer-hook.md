# Hookless plugin plus a dedicated observer hook

The native plugin `cmux-maestro-native` ships without hooks. A dedicated version-1 file, `~/.copilot/hooks/cmux-maestro-observer.json`, declares `sessionStart`, `userPromptSubmitted`, and `postToolUse`. Setup supports stable Copilot CLI 1.x with protocol 3 only, preserves unrelated hooks, plugins, settings, and disabled-hook keys, and refuses when it cannot map disable state exactly.

Why: plugin hooks cannot be disabled or migrated per key safely. One owned file can be installed, verified, and removed without touching anyone else's.

Rejected: legacy plugin-hook registration, guessing disable hashes, enabling duplicates to read keys.

Consequence: some safe-looking migrations stay blocked. Cached hooks in running sessions need a restart.

Amendment (2026-10-17, #252): setup also owns a second hook file, `~/.copilot/hooks/cmux-maestro-cmux-hooks.json`, holding CMUX 0.65.1's exact Copilot hooks (CMUX Copilot hooks in [CONTEXT](../../CONTEXT.md)). It is written with the other owned resources and removed in the same uninstall transaction. It is recognized by its bytes: Maestro owns the file only when it equals a manifest some Maestro release shipped (a closed list that only grows), so an update replaces an earlier copy and a look-alike stays foreign. Setup never replaces a file Maestro did not write and names it in the refusal; uninstall leaves it and names it. Removal moves the file aside first and verifies the bytes it moved, so a file swapped in is never deleted. Like the observer file, setup verifies it on disk only; whether Copilot loaded these hooks is not certified (setup's result already says loaded hooks are not implied), and the relaunch live checks cover it. Foreign-hook inventory and checkpoint continuity checks exclude this file through one Maestro-owned hook-source predicate shared with the observer file; a disabled CMUX Copilot hook still counts as an accounted user disable key, not an unresolved one. Validation builds never install it ([ADR 0015](0015-isolated-validation-identities.md)).
