# Transaction and recovery contract: locks and supervision

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Copilot refresh and same-build updates](copilot-refresh.md) | [Transaction and recovery contract: integrity and retained generations →](retained-generations.md)

- **CMUX Copilot hooks file.** Setup owns `~/.copilot/hooks/cmux-maestro-cmux-hooks.json` only while its bytes equal a manifest some Maestro release shipped. Update replaces an earlier copy. If setup, update or `recover` refuses and names that file, it holds hooks Maestro did not write: move it away (or remove your own CMUX hooks there) and rerun. Uninstall puts the file back if a later removal fails, and names a file it left in place.

- One kernel-held, nonblocking install lock and a private `0700` ownership
  directory live at `~/Applications/.cmux-maestro-preview-install/`. Receipts
  are `0600`, atomically written and synchronized. The persistent lock file is
  **not a stale lock** just because the caller has exited. A one-command
  Python supervisor retains the lock while a mutating `ditto`, `lsregister`
  or `pluginkit` invocation, or a non-UI integration bridge, runs. This holds
  after caller timeout or `SIGKILL`.
  The trusted integration bridge also inherits the descriptor, solely to record
  its nested provider groups. Other tools and actual provider executables do
  not receive it. Each provider starts behind an EOF-safe gate. It cannot
  execute until its separately owned group is recorded and synchronized.
  The supervisor waits for both the bridge group and every recorded provider
  group, not merely direct-child exit or pipe EOF. Killing the bridge therefore
  cannot permit restoration while its provider can still write.
  Maestro installs no daemon or persistent background observer.
- A bounded marker in that same lock file records command progress. A gated
  launcher cannot execute the tool until its private process group is durably
  recorded. If the supervisor itself exits, a new lock owner still refuses
  recovery while any recorded bridge/provider group exists, even if their
  original supervisors exited. Once all groups are gone, recovery may resume. A launcher whose
  group was never recorded cannot pass its gate. Corrupt/unverifiable markers
  fail closed. Never delete or truncate the lock to bypass this barrier.
- The 120-second command timeout ends the caller's wait, **not** a surviving
  mutator's lifetime. Wait for the protected workers to finish, then retry
  `recover`. A hung worker keeps blocking new operations, to avoid
  a delayed deregistration affecting a later installation. This supervision
  covers the fixed foreground macOS tools only. It is not a general-purpose launcher for
  programs that daemonize into independent sessions. It does not control
  unrelated operating-system services or other apps' registry requests.
