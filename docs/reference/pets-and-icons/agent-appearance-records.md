# Agent appearance records

Part of [Pets and session icons](../pets-and-icons.md). Previous page is [Choose your session icon](choose-your-session-icon-cmux-maestro.md).

All new registrations and workers default to `md-robot`.
`register`/`spawn` accept optional `--icon` and `--color` startup choices.
Saved choices survive follow-ups. They are cosmetic: never refresh execution
or Git timestamps. Bounded, private `observer/icons.json` projection matches
node/run/workspace/surface identity. It survives older supervisors republishing
`current.json` without cosmetic fields. Sidebar stays read-only over its
existing observer-directory grant.

Managed rows, collapsed icon cards and session-icon details prefer the exact
session's `--self` appearance over the controller's startup choice, per glyph
and color. Before observation binds a running managed session, its freshly read
session appearance supplies the same choice. Human overrides still win;
**Reset to agent selection** removes only the human override. Names and renamed
surfaces never select an appearance record.

Glyph font and catalog are pinned to upstream commit
`b894ea7803af6aade63d60a4381e006098ec9c4d`. Hashes, upstream license and
glyph-source notices live under `Resources/NerdFonts/`. Tests check whole
selectable catalog against actual font outlines. Missing resources or unknown
stored glyphs show explicit unavailable indicators, not font fallback.

Refresh Copilot integration through stable app's existing explicit consent
flow to install new skill, controller and catalog. Cached CLI plugins are not
rewritten or restarted automatically.

Standalone Copilot sessions can use `icon --self --session-id <current-session-uuid>`
instead of orchestration credentials. Native helper verifies caller's
actual live CLI ancestor, PID/start tuple, in-use marker and existing binding.
It refuses another surface/session, stale or ambiguous proof. It never creates
an orchestration run. Appearance records stay under existing private
bindings grant, separate from ordinary hook refreshes. Malformed appearance
data cannot invalidate lifecycle evidence. No transcript or process arguments
are read for authorization.
