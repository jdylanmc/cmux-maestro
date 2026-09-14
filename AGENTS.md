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

## Validation

Use the checked-in scripts, which select full Xcode explicitly:

```sh
./scripts/build-unsigned.sh
./scripts/test.sh
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
| `swiftui-expert-skill` | Writing, reviewing, or refactoring SwiftUI code, state flow, view composition, accessibility, animation, or performance. |
| `macos-patterns` | Using native macOS APIs or reasoning about windows, focus, activation, menus, shortcuts, file access, clipboard, drag and drop, or other platform behavior. |
| `macos-settings-ui` | Adding or changing settings and preferences UI. |
| `macos-auto-update` | Adding or changing automatic updates, Sparkle, appcasts, or update signing, but only when an issue explicitly authorizes that scope. |
| `macos-release` | Packaging, signing, notarizing, publishing, or updating an appcast, but only when an issue explicitly authorizes release scope. |
| `macos-build` | Building, testing, registering, or validating the app or extension. |

When delegating implementation or review, keep the worker's current directory
inside this repository so it can discover project-local skills. Task packets
may mention relevant skills as available context without requiring their use.
Confirm skill discovery with `/skills` or `/env` after restoring dependencies
or starting a fresh Copilot session.
