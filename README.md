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
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. `scripts/fetch-sdk.sh` fetches that
exact commit over HTTPS with Git, so Git's content addressing verifies the
acquired tree against the pin. It then records a deterministic content digest
in the ignored `vendor/.cmux-sdk-provenance` file, outside the SDK directory,
and re-verifies the cached tree before reusing it. A replacement is staged and
only swapped in once it verifies, so a failed fetch leaves the previous usable
SDK and its provenance record intact. The SDK itself lives in the ignored
`vendor/CmuxExtensionKit/` directory and is never committed.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

`build-unsigned.sh` is the automation path and disables signing. `test.sh` runs
the focused connection-state tests without requiring a development identity.
Those tests exercise the same `SidebarConnectionModel` and reducer the shipped
sidebar uses; the CMUX context and its transport are adapted to plain values at
the extension entry point, so the state logic stays directly testable.

`.github/workflows/ci.yml` runs those same two scripts, in that order, on a
macOS runner. It deliberately does not perform machine-wide `pluginkit`
registration.

## Build and register locally

No Apple Development identity is required for the local ad hoc proof:

```sh
./scripts/build-register.sh
```

The script builds with `CODE_SIGN_IDENTITY=-` and registers the embedded
extension with `pluginkit`. It derives the built product paths and the actual
`CFBundleIdentifier` from the build itself, then requires `pluginkit` discovery
to resolve that identifier to the freshly built extension's canonical path,
failing on no match, a wrong path, or an ambiguous result. Superseded
registrations left behind by earlier builds in this checkout are removed first;
a registration owned by another checkout is reported rather than rewritten.

It does not enable the extension, select it as CMUX's active sidebar provider,
or modify the legacy plugin, and it introduces no distribution signing.

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
