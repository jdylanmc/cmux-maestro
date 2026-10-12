# Build, sandbox, and identifiers

build-register, sandbox shape, bundle and plugin identifiers, upstream contracts. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Build and register locally

```sh
./scripts/build-register.sh
```

Explicit script. Builds with ad hoc identity. Verifies production
namespace and signed profiles. Then calls coordinated alpha installer.
It **does install owned Copilot integration** with stable app.
It does not enable/select sidebar, restart or adopt sessions, or modify
unrelated integrations. Build-only and validation scripts stay separate.
Xcode's own app-registration task can run during requested production
build. Installer retires only that explicitly identified development
registration. Final registration checks require production bundle ID and
canonical stable `.appex` path, not merely command success. They do not prove
hosted UI loaded.

### Historical local-build diagnostic

Already-selected preview historically kept a lost connection after replacement.
Observed workaround: right-click CMUX's sidebar toggle, select default
sidebar, then reselect **Maestro Sidebar**. In observed case, this recreated host view
and loaded replacement extension without restarting CMUX or Copilot
sessions. It is not a universal fix or proof of an OS cause.
Coordinated installer claims it neither as prerequisite nor as fallback.
Its automatic registration transition still needs stock-host acceptance.
`cmux sidebar reload` applies to interpreted Swift sidebars, not native `.appex`
extensions.

## Sandbox and distribution

Extension keeps App Sandbox enabled. Only additional file grants: 
read-only home-relative temporary exceptions, with required leading and trailing
slashes:

```text
/Library/Application Support/CMUXMaestroPreview/Copilot/
/.copilot/session-state/
```

No network client/server or arbitrary process/data access entitlement added.
Installer app and identity command-line helper are unsandboxed. They must
run explicitly selected CLI and write own integration data. This is a
personal native distribution tradeoff, **not a claim of Mac App Store
compatibility**. Temporary file exceptions require distribution/review scrutiny.

Separately signed sandbox probe established: these exact read-only
prefixes permit synthetic nested identity/event reconstruction. Unrelated reads and writes
stay denied. That is **not** an
ExtensionKit-hosted runtime proof. Signed app/host loading and end-to-end
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
`copilot plugin install <absolute-path>`. Uninstall uses manifest name.
Installed CLI currently accepts absolute local paths. It warns that direct
repository, URL, and local-path installation is deprecated for a future release.
CMUX Maestro intentionally keeps working local-preview path. Public
marketplace or release infrastructure stays out of scope.
Hook manifests follow [command-hook
reference](https://docs.github.com/en/copilot/reference/hooks-reference), including
`version: 1`, `type: command`, `bash`, and `timeoutSec`.
