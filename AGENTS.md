# CMUX Maestro Agent Guide

## Project boundary

CMUX Maestro is a personal, public, open-source macOS project owned by
`jdylanmc`. Keep all content generic and free of employer-confidential material.

The repository currently contains a minimal containing app and sandboxed CMUX
ExtensionKit sidebar. The legacy interpreted Maestro repository is independent:
do not copy its source or history, modify it, or make this project depend on it.

## Structure

- `CMUXMaestroPreview/`: macOS containing app.
- `CMUXMaestroSidebar/`: sandboxed ExtensionKit sidebar.
- `CMUXMaestroPreviewTests/`: focused Swift tests.
- `CMUXMaestroPreview.xcodeproj/`: Xcode project and shared scheme.
- `scripts/`: pinned SDK fetch, build, test, and local registration commands.
- `.agents/skills/cmux-maestro-orchestrate/`: repository-owned installed
  terminal orchestration skill.
- `skills/maestro/`: confirmed intent and globally distributed peer discovery/
  send/reply guide; reuse the lifecycle skill instead of duplicating it.
  Distribute only through the human-run `npx skills` command in Settings >
  CLI Integration, not app resources or the runtime plugin.
- `scripts/delivery-proof/adapter.mjs`: shared installed native-session
  adapter and backwards-compatible disposable proof transport.
- `vendor/CmuxExtensionKit/`: ignored local SDK checkout created by the fetch
  script. Never commit it.

## Constraints

- Keep bundle identifiers under `com.jdylanmc.CMUXMaestroPreview`.
- Keep the extension point `com.cmuxterm.app.cmux.sidebar`.
- Keep App Sandbox enabled on the extension.
- Request the minimum CMUX manifest scopes needed by current UI.
- Do not add live provider data, daemons, hooks, transports, taskboards, domain
  models, fixtures presented as real data, packaging, or migration logic unless
  a later issue explicitly approves that scope.
- Do not add a license until the repository's licensing issue is resolved.
- Keep orchestration control outside the sandboxed sidebar. The sidebar may
  read only sanitized bounded metadata from the exact `Orchestration/observer/`
  grant and use typed host navigation; never add
  raw prompts/results/tokens, a daemon, loopback server, socket client, focus
  inference, automatic tool approval, or automatic terminal/process cleanup.
- New workers are interactive Copilot sessions with inherited terminal I/O and
  direct human follow-ups. Do not create new headless-worker tabs or infer task
  completion from an interactive session's exit. Issue #54's confirmed product
  expansion permits the installed native-session adapter, same-workspace peer
  discovery/send/reply, explicit installer/build resources and
  global `/maestro` guide,
  reusing `scripts/delivery-proof/` and the existing pinned launcher.
  Newly launched managed participants receive wiring automatically; never adopt
  or restart an existing/unmanaged session. Its same-workspace peer messaging is
  fire-and-forget, independent of visual focus, and grants no process control.
  Preserve human typing/drafts; do not use terminal keystrokes as a fallback.
  Copilot owns prompt scheduling; add no custom busy scheduler, acknowledgements,
  receipts, retries, completion tracker, or beat timer. Only the existing explicit
  production setup action may install the inert native loader; no constructor
  side effects, host changes, generic plugin framework or standalone broker.
  Preserve existing legacy bounded workers.
  Legacy reported outcomes require a strict whole-final-message generation
  report plus verified process/result boundary. Report-missing or permission-
  denied recovery requires that exact current-generation boundary and exact
  session resume. Archive/recovery must never guess ownership, kill a process,
  delete a terminal, or bypass the still-live resource bound.
- Preserve the launch lease across external surface creation and attachment.
  Archive must not cross an active lease, and every exact created surface must
  remain owned or retained. Interactive I/O belongs to the terminal, not a JSON
  capture loop; legacy turn I/O stays bounded while heartbeats and visible
  provider diagnostics continue. Never infer success or approve a prompt.
- Keep Copilot tool policy explicit, bounded and private. Add no grants by
  default; preserve denies and descendant non-escalation. Provider policy flags
  are not an operating-system sandbox or a lifecycle reporting channel.
  Explicit user-approved coordinator `spawn --yolo` (and the preserved proof
  alias `--delivery-proof-yolo`) may use Copilot `--allow-all`, preserving denies.
  Reject either YOLO request from a worker actor before credential resolution or
  reservation. Do not infer full parent permissions, auto-answer prompts, or
  change persistent Copilot settings; normal defaults add no grants.
- Preserve exact workspace/surface/session/generation ownership and the
  controller's depth, node, size and concurrent-operation bounds.

## Validation

Use the checked-in scripts, which select full Xcode explicitly:

```sh
./scripts/build-unsigned.sh
./scripts/test.sh
python3 scripts/test-cmux-maestro-orchestrator.py
./scripts/build-register.sh
```

Before committing, confirm `git status --short` contains no fetched SDK or build
products. Configure repository-local Git author identity as Dylan McCurry
`<j.dylan.mccurry@gmail.com>`. Do not add a co-author trailer.

## Project skills

Project-local agent skill files, references, and helpers under `.agents/skills/`
are committed alongside `skills-lock.json`. A normal checkout includes the
reviewed skill set; do not ignore these files or require installation just to
make them available. If dependency files are missing, restore them with:

```sh
npx skills experimental_install
```

Review restored files and lockfile changes before committing. Preserve bundled
upstream notices and the dependency attribution in
[`.agents/THIRD_PARTY_NOTICES.md`](.agents/THIRD_PARTY_NOTICES.md); these notices
do not select a license for the Maestro product.

The repository-owned `macos-build`, `cmux-maestro-orchestrate`, and
`maestro-icon` skills are maintained here. Preserve those local adaptations
when restoring or refreshing dependencies.

Workflow skills from `jdylanmc/agent-skills` are installed project-locally for
GitHub Copilot. To add or refresh that package's discoverable skills, run:

```sh
npx --yes skills add jdylanmc/agent-skills --skill '*' --agent github-copilot --copy -y
npx --yes skills remove joe-mode-orca --yes
```

Keep the wildcard quoted. This refreshes the existing upstream workflow skills,
then removes the intentionally excluded Orca coordinator from the project.
Commit the changed `.agents/skills/` files and lockfile together.
These commands do not install globally.
The lock records sources and content hashes,
not immutable upstream revisions, so review lockfile changes after restoring
or refreshing skills.

The upstream CMUX skillset is also installed project-locally for GitHub Copilot:

```sh
npx --yes skills add https://github.com/manaflow-ai/cmux --skill '*' --agent github-copilot --copy --yes
```

Use its `cmux-workspace`, `cmux`, `cmux-browser`, and `cmux-diagnostics` guides
for applicable host operations. Contributor-oriented guides apply when working
on upstream CMUX; their repository paths and build commands do not replace
this project's checked-in scripts or native ExtensionKit boundaries.
`cmux-custom-sidebar` describes the separate interpreted sidebar system, not
this application's implementation. `cmux-cua` still requires the user's
explicit request; installing the guide grants no computer-use permission.
Keep Maestro spawning and peer messaging on the existing lifecycle/native
adapter path. These skills neither enable that adapter nor adopt existing
sessions. Restore missing dependency files with `npx skills experimental_install`;
review and commit the skill files and lockfile together.

These skills are available as contextual guidance. Agents should use them when
they materially improve the work, while retaining judgment for simple or
unrelated tasks:

| Skill | Useful context |
| --- | --- |
| `swiftui-design-skill` | Reviewing visual hierarchy, information density, progressive disclosure, and design direction. |
| `swiftui-design-principles` | Applying restrained native styling, consistent spacing, typography, and semantic colors. |
| `swiftui-expert-skill` | Writing, reviewing, or refactoring SwiftUI code, state flow, view composition, accessibility, animation, or performance. |
| `macos-patterns` | Using native macOS APIs or reasoning about windows, focus, activation, menus, shortcuts, file access, clipboard, drag and drop, or other platform behavior. |
| `macos-settings-ui` | Adding or changing settings and preferences UI. |
| `macos-auto-update` | Adding or changing automatic updates, Sparkle, appcasts, or update signing, but only when an issue explicitly authorizes that scope. |
| `macos-release` | Packaging, signing, notarizing, publishing, or updating an appcast, but only when an issue explicitly authorizes release scope. |
| `macos-build` | Building, testing, registering, or validating the app or extension. |

Apply design guidance in the context of the macOS 14 ExtensionKit sidebar.
Mobile-only APIs, touch-target sizes, large headings, and layout examples do
not override the deployment target, accessibility needs, or established
runtime safeguards.

When delegating implementation or review, keep the worker's current directory
inside this repository so it can discover project-local skills. Task packets
may mention relevant skills as available context without requiring their use.
Confirm skill discovery with `/skills` or `/env` after restoring dependencies
or starting a fresh Copilot session.

## Agent skills

### Issue tracker

Use GitHub Issues in `jdylanmc/cmux-maestro`. The default backlog is all open
issues in that repository, not assigned-to-me. An explicit issue or epic request
narrows the selection. See
[`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md).

### Triage labels

Use the five canonical GitHub labels mapped in
[`docs/agents/triage-labels.md`](docs/agents/triage-labels.md).
Configuration does not authorize issue mutations or mark work ready.

### Domain docs

Use single-context documentation, created lazily. See
[`docs/agents/domain.md`](docs/agents/domain.md); do not scaffold speculative
context or decisions.

### Commit messages

Use the terse Conventional Commits policy in
[`docs/agents/commit-style.md`](docs/agents/commit-style.md), preserving the
repository's author identity and no-co-author rule. Formatting grants no
staging, commit, or history-rewrite authority.

### Doctrine

The installed package is `.agents/skills/doctrine/`. Use its `SKILL.md` and
`APPLY.md`; `/doctrine` without arguments lists metadata, and named IDs load
verified full text. Keep the manifest, sources, and helper together.
Repository-wide required IDs: none beyond workflow requirements.
PR-producing workflows require `worktrees`; code Roast requires `solid`.
Orchestrators provide scoped selections and workers load the assigned sources.
Preserve operator choices for that delivery, not unrelated work. Missing local
packages are capability blockers, not permission to alter global settings.

### Joe delivery and merge policy

See [`docs/agents/merge-policy.md`](docs/agents/merge-policy.md) for the
four-developer pool, standalone worktrees, installed Maestro lifecycle and
native `/maestro` messaging, independent review, and human-authorized PR Sniper
merge gate. Authors stop at candidates; this guide does not authorize merging,
timers, services, or live-session changes.
