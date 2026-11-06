# Update, rollback and status

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Install a verified artifact](verified-artifact.md) | [Copilot refresh and same-build updates →](copilot-refresh.md)

Updates journal and verify their candidate, then automatically withdraw
only the receipt-owned app/extension registration. The installer verifies
registration absence, then waits up to 120 seconds for positively identified
preview executables to exit before replacing the app. It re-registers the stable
app afterward. Selecting CMUX's Default sidebar is not an installer prerequisite.
`cmux sidebar reload` is not used.

The installer handles a running receipt-owned containing app automatically. It
journals the process generation, code identity and hidden state, then requests
a normal quit through `NSRunningApplication.terminate()`. Exact bundle and
executable paths, owner/start generation and running code identity must match.
Same-name apps, other copies, extensions and helpers are not quit targets.
An accepted quit request is not exit proof. The existing kernel process guard
must still observe release before replacement. Refusal or continued execution
aborts safely, without force termination.

If the containing app was running, successful update or failure recovery
restores a verified instance of the appropriate app through `NSWorkspace` at
the exact path. Launch disables activation, other-app hiding, version
substitution, duplicate-instance creation, recent-item changes and optional
system prompts. An already-running exact instance is reused without activation.
Quarantined apps refuse background relaunch, to avoid Gatekeeper UI
or changing quarantine/permission settings. An app that was previously closed
stays closed. An identical verified install does not quit or relaunch it.
Relaunch intent/results are journaled for interrupted recovery.

Helpers, extensions and unverifiable processes still block replacement.
They are never force-killed. No operation quits CMUX, restarts a CLI session,
injects terminal input or uses an activation/keystroke fallback.
Hosted native acceptance
is still required.

An unrelated application's updater can leave a live process whose old executable
path was deleted. For that missing-path condition only, the installer
compares the kernel-cached executable code-directory hash with every Mach-O
architecture in the receipt-verified preview apps and backups. It requires
unchanged bundle contents, process ownership/start time and executable identity.
A matching hash, missing signature, unsupported/partial inventory, changed
evidence or permission denial still blocks the update. No process is exempted
by name or terminated. Mapped-library listings are not used as proof of the
running executable's identity.

The older **`prepare-update`** operation remains an optional explicit
registration-withdrawal diagnostic. It is not a required step. Update and rollback
perform withdrawal themselves. Preparation does not delete or replace app
files, change plugin settings or signal any process. If preparation is
interrupted or you decide not to update, **`recover`** restores the current
registration. Until update/rollback/recovery completes, `status` can report the
expected missing registration. An identical no-op correctly requires that
registration to be present.

```sh
# For a separately built production artifact:
python3 scripts/local-preview.py update \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
python3 scripts/local-preview.py status

# Legacy app-only historical rollback (separate integration maintenance):
python3 scripts/local-preview.py rollback

# Cancel preparation without changing the installed build:
python3 scripts/local-preview.py recover
```

[Limit](../../evidence/reference.md#update-rollback-and-status).
