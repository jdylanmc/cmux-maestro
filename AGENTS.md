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
  completion from an interactive session's exit. Issue #54 permits the opt-in
  disposable native-extension delivery proof in `scripts/delivery-proof/`,
  using the existing pinned launcher. Its same-workspace peer messaging is
  fire-and-forget, independent of visual focus, and grants no process control.
  Preserve human typing/drafts; do not use terminal keystrokes as a fallback.
  Copilot owns prompt scheduling; add no custom busy scheduler, acknowledgements,
  receipts, retries, completion tracker, or beat timer. No installed-integration
  replacement or host change is authorized by this exception.
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
  Issue #54 additionally permits explicit per-spawn `--delivery-proof-yolo` for
  disposable proof workers only, using Copilot `--allow-all` while preserving
  explicit denies. Do not infer parent permissions, auto-answer prompts, or
  change persistent Copilot settings; ordinary workers remain unchanged.
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

Project-local agent skill dependencies are recorded in `skills-lock.json`.
Restore the recorded skill set with:

```sh
npx skills experimental_install
```

The restored third-party copies under `.agents/skills/` are generated and
ignored. The repository-owned `.agents/skills/macos-build/SKILL.md` is the
exception: it adapts build guidance to the checked-in validation scripts and is
reviewed with the rest of the project.

Workflow skills from `jdylanmc/agent-skills` are installed project-locally for
GitHub Copilot. To add or refresh that package's discoverable skills, run:

```sh
npx --yes skills add jdylanmc/agent-skills --skill '*' --agent github-copilot --copy -y
```

Keep the wildcard quoted. This installs the existing upstream skills (33 at
this update), not newly authored skills. Their copies also live under the
ignored `.agents/skills/` directory; commit the lockfile, not generated copies.
Neither command installs globally. The lock records sources and content hashes,
not immutable upstream revisions, so review lockfile changes after restoring
or refreshing skills.

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
