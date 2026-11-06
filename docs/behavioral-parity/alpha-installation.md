# Coordinated alpha installation (#114)

Part of [behavioral parity and proof](../behavioral-parity.md). Continued in [retired slots and native publication](install-retired-slots.md), [integration checkpoint](install-integration-checkpoint.md) and [plugin identity and disabled state](install-plugin-state.md). Next page is [Alpha installation: retired slots and native publication](install-retired-slots.md).

The focused Python suite covers ordinary `install` upgrades, exact registered
identical no-ops (without app replacement, receipt changes or lost backups),
automatic restoration after copy/exchange/registration failures, first-install
absence, interrupted restoration, exact development-source registration
restoration and refusal to race an unfinished command guardian. Existing
ownership, integrity, process identity and partial-cleanup controls remain.
Changed-app publication withdraws only the owned registration, waits at most
120 seconds for positively identified preview processes to exit, and registers
the replacement. Unknown process evidence still fails immediately. Tests cover
ordered withdrawal/re-registration, unchanged unrelated registrations, bounded
waiting and restoration when release fails; no UI selection, host restart or
script-sidebar reload is used.
The normal containing app is no longer treated as an indefinitely busy
extension. A changed-app update journals the exact running app's owner/start
generation, executable and code identity, then requests only
`NSRunningApplication.terminate()`. Refusal or failure to exit aborts without
force termination. The prior running/hidden choice is restored with an exact
URL `NSWorkspace` launch configured not to activate, hide other apps, substitute
another installation, create a duplicate instance or prompt for optional UI.
Quarantine refuses relaunch rather than bypassing system policy.

Injected AppKit handles cover ownership mismatches, PID-generation changes,
other app copies, helper/extension exclusion, refusal and idempotent restoration.
A separate non-UI process fixture compares the public Security-framework code
identity with the existing kernel-cached code hash. Installer tests cover
quit/launch interruptions, failed restoration and rollback after a replacement
app has started. These tests do not invoke real GUI quit/launch; the hosted
stock-host proof must still establish real release/recreation and focus behavior.

The receipt now distinguishes a healthy `retired` slot from unresolved
`garbage` deletion. Older schema-1 receipts without `retired` remain readable.
Slot aliases and more than four managed bundles during preparation (three after
completion) are rejected. Current and previous remain the working/rollback
generations; retired is disposable maintenance, not an extra active install.
A verified no-op neither deletes retirement nor republishes registration.
