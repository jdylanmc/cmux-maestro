# CMUX Maestro

CMUX Maestro is an independent compiled macOS sidebar preview for CMUX. This
bootstrap proves the containing-app and sandboxed ExtensionKit boundary before
any provider integration is introduced.

The sidebar intentionally shows only its CMUX connection health:

- **Waiting** while the host connection or first snapshot is unavailable.
- **Connected** with counts derived from the CMUX-provided snapshot.
- **Degraded** when CMUX reports a connection error.

No live agent-provider data, observer daemon, hooks, transport, or Agent Session
fixtures are included. The existing interpreted Maestro remains a separate,
untouched project and can continue to be used alongside this preview.

## Requirements

- macOS 14 or newer
- Xcode 26.6 at `/Applications/Xcode.app`
- CMUX with sidebar ExtensionKit support

The project uses the CMUX ExtensionKit package from pinned CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. The SDK is fetched into the ignored
`vendor/CmuxExtensionKit/` directory and is never committed.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

`build-unsigned.sh` is the automation path and disables signing. `test.sh` runs
the focused connection-state tests without requiring a development identity.

## Build and register locally

No Apple Development identity is required for the local ad hoc proof:

```sh
./scripts/build-register.sh
```

The script builds with `CODE_SIGN_IDENTITY=-`, registers the embedded extension
with `pluginkit`, and verifies discovery of
`com.jdylanmc.CMUXMaestroPreview.Extension`. It does not enable the extension,
select it as CMUX's active sidebar provider, or modify the legacy plugin.

To use the preview afterward, open CMUX's Sidebar Extensions browser, enable
**CMUX Maestro Preview**, and select it manually.

## Identifiers

| Component | Identifier |
| --- | --- |
| Containing app | `com.jdylanmc.CMUXMaestroPreview` |
| Sidebar extension | `com.jdylanmc.CMUXMaestroPreview.Extension` |
| Extension point | `com.cmuxterm.app.cmux.sidebar` |

The structure follows the official CMUX
`Examples/SampleSidebarExtensionApp` reference at the pinned commit, with its
sample feature UI removed.
