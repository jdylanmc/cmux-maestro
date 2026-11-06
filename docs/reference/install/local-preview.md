# Install a stable local preview

Part of [install, update, and recovery](../install-update-recovery.md). Next page is [Install a verified artifact](verified-artifact.md).

This is a **local, user-owned preview**. It is not a public release, auto-updater,
notarized distribution, license decision, or legacy-plugin cutover. Stable
default: **`~/Applications/CMUX Maestro Preview.app`**. App, extension and
bundled helper do not depend on a disposable Git worktree after install.
The Python 3 command uses the standard library and macOS `ditto`, `codesign`,
LaunchServices and `pluginkit`. It does not install a service or dependency.

The alpha installer coordinates the app and its owned Copilot integration as
one journaled operation. The owned-source boundary uses public
exact-source identity for the fixed owned path. It rejects foreign or unproven
owned provenance. Unrelated plugins are preserved, not certified.
**Issue #114 still requires current-head independent review, full hosted CI,
combined installer/native-host acceptance and guarded live installed-session
acceptance.** Registration withdrawal/re-registration or earlier native-only
proof does not establish the current combined artifact's loaded-generation
behavior or live acceptance.

Before native retirement, the installer queries the exact production extension
identifier and public sidebar extension point. It reports eligible external
same-ID paths. It does not change the app first and discover a blocked native
reload afterward. It recognizes receipt-owned paths and this checkout's verified development
source. Retire the latter only with the explicit
`--retire-development-registration` option. Ignored/superseded records are
preserved. Unknown or debugger-only election is reported as ambiguity. Other
identifiers/extension points and unrelated Copilot plugins are outside this check.
Historical external registrations need a separate ownership/consent decision.
Do not adopt them, sweep a namespace or treat them as a routine manual-uninstall step.

From a trusted checkout, build and install the development-signed alpha explicitly:

```sh
./scripts/build-register.sh --provisioning-profile /absolute/path/to/development.provisionprofile
```

Use an existing macOS development certificate with its private key and an
unexpired development profile for **com.jdylanmc.CMUXMaestroPreview**, enabling
only Communication Notifications beyond standard development identity grants.
The profile must contain this Mac's **provisioning_UDID** (not its hardware UUID)
and match the certificate's team. Exactly one usable profile-authorized identity
must be present. Missing or ambiguous identity refuses. No certificate is created,
imported, revoked or selected arbitrarily. The path is explicit each invocation;
no credential/profile configuration is saved.

Before building, the script verifies the CMS signature against system Apple
roots and the macOS provisioning authority, dates, app/team, device, capabilities
and existing identity. Verification does not import CMS certificates or permit
network trust fetching. Profile opens are nonblocking and descriptor-validated;
special files such as writerless FIFOs refuse rather than blocking before validation.
Keychain signing permission/unlock prompts remain human
actions. A timeout never force-stops the signing writer.
The original signed profile is embedded only in the
containing app. App, sidebar, helper and debug libraries share one certificate;
the sidebar retains its exact sandbox grants and unchanged ID. Helper/libraries
get no restricted app entitlements. The containing app alone receives the
communication and app/team identity entitlements, never debugging access.
On macOS, `com.apple.security.get-task-allow` is unrestricted and need not appear
in a development profile ([Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles#Entitlements-on-macOS)).
An absent or boolean profile value is accepted without claiming that entitlement.
Unsigned/test namespaces remain separate.

Ad-hoc signing is only an intermediate build step, never an accepted new
publication or fallback. Post-sign and staged-copy checks enumerate each native
component's architectures and enforce its role's entitlements on every slice:
exact app profile, approved sidebar sandbox/grants, none for helper/libraries.
They also require authorized same-certificate native code (all architectures) and
the embedded profile. A failed step stops before installation, without an automatic retry.
Never commit profiles, private keys or certificate exports. The existing
`.build/adhoc` path is retained solely for exact source-registration ownership.
