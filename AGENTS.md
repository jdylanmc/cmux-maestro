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
