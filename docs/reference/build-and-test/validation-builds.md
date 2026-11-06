# Validation builds

Part of [Build and test](../build-and-test.md). Previous page is [Setup controls and focused diagnostics](setup-controls-and-focused-diagnostics.md). Next page is [Isolated setup, hook and sandbox checks](isolated-setup-hook-and-sandbox-checks.md).

Xcode can register macOS app outputs with LaunchServices even when signing is
disabled. Validation builds therefore use isolated identities **and** isolated
extension points. No supported registration-suppression setting exists:

| Script | App bundle ID suffix | Extension point |
| --- | --- | --- |
| `build-unsigned.sh` | `.Validation.Unsigned` | `com.jdylanmc.CMUXMaestroPreview.validation.unsigned.sidebar` |
| `test.sh` | `.Validation.Tests` | `com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar` |

Sidebar, helper and test bundle IDs use the same suffix. These copies cannot
replace production identity or appear under CMUX's real sidebar point,
even if Xcode registers them. They are validation artifacts, not installable
CMUX sidebar providers. Do not use their installer UI for integration setup.
Scripts verify resolved settings before building and
resulting app/extension metadata afterward. Run these scripts, not
an unqualified application build, while a native integration is installed.

Validation builds also compile a settings-only app scene: test runs do not open
the Copilot setup window. If opened manually, a validation copy shows only a
read-only explanation. Install and uninstall are rejected before executable
lookup, filesystem access, or CLI invocation unless containing app has the
exact production bundle identity. Use installed production app for setup,
never a window labelled **Test Validation** or **Unsigned Validation**.
Resolved build checks require the no-window compilation condition for validation
and reject it for production. Tests cover both zero-window host and
zero-side-effect install/uninstall denial. Fake production setup tests explicitly
inject production identity.
