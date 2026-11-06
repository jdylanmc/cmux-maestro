# Coordinated alpha installation (#114)

[↑ Behavioral parity and proof](../behavioral-parity.md) | [Alpha installation: retired slots and native publication →](install-retired-slots.md)

Focused Python tests cover ordinary `install` upgrades, exact registered
identical no-ops (no app replacement, receipt change or lost backup), automatic
restoration after copy, exchange or registration failure, first-install
absence, interrupted restoration, exact development-source registration
restoration, and refusal to race an unfinished command guardian. Existing
ownership, integrity, process-identity and partial-cleanup controls remain.

Changed-app publication withdraws only the owned registration, waits at most
120 seconds for positively identified preview processes to exit, then registers
the replacement. Unknown process evidence fails immediately. Tests cover
ordered withdrawal and re-registration, untouched unrelated registrations,
bounded waiting and restoration when release fails, with no UI selection, host
restart or script-sidebar reload.

The containing app is not an indefinitely busy extension. A changed-app update
journals the running app's exact owner/start generation, executable and code
identity, then requests only `NSRunningApplication.terminate()`. Refusal or
failure to exit aborts without force termination. An exact-URL `NSWorkspace`
launch restores the prior running/hidden choice without activating, hiding
other apps, substituting another installation, duplicating the instance or
prompting for optional UI. Quarantine refuses relaunch instead of bypassing
system policy.

Injected AppKit handles cover ownership mismatches, PID-generation changes,
other app copies, helper/extension exclusion, refusal and idempotent
restoration. A non-UI process fixture compares the public Security-framework
code identity with the kernel-cached code hash. Installer tests cover
quit/launch interruptions, failed restoration and rollback after a replacement
app started. None invokes real GUI quit/launch; the hosted stock-host proof
must still establish real release/recreation and focus behavior.

The receipt separates a healthy `retired` slot from unresolved `garbage`
deletion. Older schema-1 receipts without `retired` remain readable. Slot aliases
and more than four managed bundles during preparation (three after completion)
are rejected. Current and previous are the working and rollback generations.
Retired is disposable maintenance, not an extra active install. A verified
no-op neither deletes retirement nor republishes registration.
