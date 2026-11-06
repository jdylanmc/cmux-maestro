# Install a verified artifact

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Install a stable local preview](local-preview.md) | [Update, rollback and status →](update-and-rollback.md)

To install an already-built, verified production artifact instead:

```sh
python3 scripts/local-preview.py install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
```

Both commands are **explicit publication actions**, not validation commands.
`build-register.sh` validates the built product, then invokes the same coordinated installer.
It does not separately publish the development extension.
Xcode can still register its source app during the build. No
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` setting is supported. The install command stages and
verifies the signed copy, installs it atomically, then retires **only this
checkout's known `.build/adhoc` registration** before registering the stable
app and extension. The flag is optional for separately supplied signed
artifacts. No other development copies are discovered or deregistered.
Source files are **never removed**.

The helper target supplies its resolved production/validation
identifier to `codesign` explicitly. Otherwise a command-line tool can keep its
linker-generated identifier despite `PRODUCT_BUNDLE_IDENTIFIER`. Publication
and installation verify the effective helper identity. Rebuild older products
with linker-generated helper IDs. They are not accepted as install sources.
The helper's optional `com.apple.application-identifier` entitlement must match
that exact identity. It does not permit additional access entitlements.

The command confirms the exact production bundle ID and canonical path in
both LaunchServices and the extension registry. Exit status zero is not enough.
The extension parser accepts pluginkit's documented election markers, including
`=` (superseded) and `?` (unknown). Retained sibling registrations do not prevent
an exact match. They are never removed merely for appearing in the listing.

Copilot setup is included. The installer invokes a production-only, non-UI
bridge from its verified candidate, preserving the stable destination helper
path. It checkpoints the prior owned state before replacement. It keeps the
app receipt/previous-generation retention pending until setup, public discovery
and exact app registration succeed. No setup window, separate Enable
action or chat restart is required. Both commands accept an explicit `--copilot-executable` option
when the intended CLI is not on `PATH`.
New source artifacts must advertise the signed `copilot-install-v1` and
`graceful-lifecycle-v1` capabilities in their containing-app metadata.
Both configurations merge these custom markers from
`CMUXMaestroPreview/Info.plist`. Xcode still generates the namespace-specific
bundle identifiers and versions. Arbitrary `INFOPLIST_KEY_*` build settings
alone do not emit these custom keys.
Older installed apps can still be
upgraded or restored. An old source artifact lacking the bridge is rejected
before launch, to avoid its GUI interpreting an unknown argument.
Completion reports configured all/subset disables or unresolved disable-key
applicability separately from ordinary current-on-disk state.

[Limit](../../evidence/reference.md#install-a-verified-artifact).
