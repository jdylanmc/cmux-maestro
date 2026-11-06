# Build, sandbox, and identifiers

build-register, sandbox shape, bundle and plugin identifiers, upstream contracts. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Build and register locally

```sh
./scripts/build-register.sh --provisioning-profile /absolute/path/to/development.provisionprofile
```

This explicit script preflights the supplied production development profile and
one usable existing identity, prepares a local build, then signs all native
components with that identity. Only the containing app embeds the Communication
Notifications profile. The script verifies production namespace, profile, signer
consistency and exact entitlements before calling the coordinated alpha
installer, with no new ad-hoc publication
([profile prerequisites](install-update-recovery.md)). It **does install owned
Copilot integration** with the stable app. It does not enable/select the
sidebar, restart or adopt sessions, or modify unrelated integrations.
Build-only and validation scripts remain separate. Xcode's own app-registration
task can run during a requested production build, and the installer retires
only that explicitly identified development registration. Final registration
checks require the production bundle ID and canonical stable `.appex` path, not
merely command success, and do not prove the hosted UI loaded.

### Historical local-build diagnostic

## Sandbox and distribution

The extension keeps App Sandbox enabled. Its only additional file grants are
home-relative temporary exceptions, with required leading and trailing slashes,
all read-only except the Beats store
([ADR 0020](../adr/0020-sidebar-writes-beats-store-outside-its-container.md)):

```text
read-only /Library/Application Support/CMUXMaestroPreview/Copilot/
read-only /Library/Application Support/CMUXMaestroPreview/Orchestration/observer/
read-only /.copilot/session-state/
read-write /Library/Application Support/CMUXMaestroPreview/Beats/
```

No network client/server or arbitrary process/data access entitlement is added.
The installer app and identity command-line helper are unsandboxed because they
must run the explicitly selected CLI and write their own integration data. This
is a personal native distribution tradeoff, **not a claim of Mac App Store
compatibility**. Temporary file exceptions require distribution/review scrutiny.

Signed app/host loading and end-to-end
installation remain explicit manual verification gates.

## Identifiers and upstream contracts

| Component | Identifier |
| --- | --- |
| Containing app | `com.jdylanmc.CMUXMaestroPreview` |
| Sidebar extension | `com.jdylanmc.CMUXMaestroPreview.Extension` |
| Identity helper | `com.jdylanmc.CMUXMaestroPreview.CopilotHook` |
| Extension point | `com.cmuxterm.app.cmux.sidebar` |
| Copilot plugin | `cmux-maestro-native` |

Install follows GitHub's [local plugin
instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-creating):
`copilot plugin install <absolute-path>`, and uninstall uses the manifest name.
The installed CLI accepts absolute local paths but warns that direct
repository, URL and local-path installation is deprecated for a future release.
CMUX Maestro deliberately keeps the working local-preview path; public
marketplace or release infrastructure is out of scope.
Hook manifests follow [command-hook
reference](https://docs.github.com/en/copilot/reference/hooks-reference), including
`version: 1`, `type: command`, `bash`, and `timeoutSec`.

[Historical diagnostics and sandbox probe](../evidence/reference.md#build-sandbox-and-identifiers).
