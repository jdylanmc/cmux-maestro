# Guide distribution decision after live proof

Part of the [native delivery proof](../delivery-proof.md). Previous page is [Delivery proof: source grounding and live observations](source-grounding.md). Next page is [Parent-only preparation and live launch](live-launch.md).

Parent research against the exact `1.0.87-0` executable found the installed
`cmux-maestro-native` `1.1.0` plugin enabled in CLI discovery, while a fresh
interactive session's skill registry omitted `maestro`. Native messaging worked;
bare skill-tool invocation failed. The upstream cause is not established.
`joinSession` with unspecified discovery/plugin options does not justify resetting
configuration. The tool identifier is `maestro`, not
`cmux-maestro-native:maestro`. The latter was the plugin slash UI namespace.

The parent later reported **live failures with both bare plugin loading
and the explicit `--plugin-dir` mitigation**. Source loading order and mocked
launcher tests did not establish live interactive skill availability. No
upstream root cause was demonstrated. The workaround is removed, not advertised
as a fix.

**User-observed success at `2026-09-22T12:03:56.533Z`:** `npx skills` **1.5.26**
installed the local-source guide globally at `~/.agents/skills/maestro`, and
Copilot global discovery succeeded. The user chose this as the **one canonical
guide distribution**. The location is evidence for that run, not a hardcoded
`.copilot` global-path assumption. Global invocation is **`/maestro`** or
**`{"skill":"maestro"}`**, without additional required activation grants.

Native Maestro **Settings > CLI Integration** now presents the purpose,
selectable command and one copy button in a minimal native section. Richer card,
status detection, update and coverage flows are deferred for separate backlog
tracking by the parent. They do not block messaging. The section has no local
scan, re-check action, remote freshness claim or embedded terminal. The command is:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy
```

The human must run it and review interactive confirmation. Settings executes
nothing, opens no terminal/browser, and touches no global skill. This GitHub-source
command needs the skill merged to `main`. For development/PR acceptance, from the
checkout root the human may instead run:

```sh
npx skills add . --skill maestro --agent github-copilot --global --copy
```

No movable branch ref or release machinery is embedded. The user's working
global local-source copy is not refreshed by this author; any content refresh
remains parent/user-consented.

Runtime installation stays in **Enable Copilot Integration**. The guide never
installs runtime and messaging remains usable without it. The canonical source
is `skills/maestro/{SKILL.md,intent.md}`; it is no longer bundled into app resources
or copied into the runtime plugin. Lifecycle/icon plugin skills remain.
Explicit setup removes only its obsolete `Copilot/plugin/skills/maestro/SKILL.md`
using existing owned-directory patterns, refusing symlinks and preserving
unrelated/global skills and other files. This correction does not mutate installed
live files or cached sessions.

Setup writes `{version, routes, extension}`. The launcher cheaply ignores an old
`pluginDirectory` field and never validates or passes it to Copilot. Both old
and new stored nodes retain the three-field contract; no guide-driven setup
upgrade is required. Pins, denies, coordinator-only explicit `--allow-all`,
native `--experimental`, terminal I/O and all R1-R5 lifecycle fixes are retained.
The change adds no receipts, retries, custom scheduling, new timers or host changes.
