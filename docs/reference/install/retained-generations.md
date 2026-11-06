# Transaction and recovery contract: integrity and retained generations

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Transaction and recovery contract: locks and supervision](transaction-contract.md) | [Transaction and recovery contract: integration checkpoint →](integration-checkpoint.md)

- Source and staged copy must match an integrity receipt and pass effective
  signed-profile verification. Files and directory metadata are synchronized
  before commit. Darwin `renamex_np(RENAME_SWAP)` exchanges an update/rollback
  with the live destination in one operation: no deliberate
  missing-app interval exists. First install uses exclusive rename. Unsupported
  filesystems fail closed. No non-atomic replacement fallback exists.
- A completed update retains **one verified previous app** in an owned slot.
  It may also retain **one inactive retired app**, separate from that required
  rollback generation. Preparation permits at most **four** managed bundles:
  current, previous, retired and one staging candidate. Completion returns to
  at most **three**: current, previous and retired. These are archival bounds,
  not additional active installations or process permissions.
- A healthy retired slot does not block a verified identical install or trigger
  housekeeping. Stage and verify a changed candidate before reclaiming
  the old retired slot. Reclamation is journaled. It occurs only while the
  owned native registration is withdrawn and relevant owned processes are
  idle. Partial staging remains unverified node-owned cleanup, never a trusted
  retired artifact.
- Successful update retains the old previous generation as retired. Failed
  update retains the verified failed candidate after restoring the original
  current/previous generations. Its bridge remains available for compensation,
  checkpoint release and non-activating relaunch, even when the older app has
  no bridge. All owned registration retirement precedes final publication.
  No same-ID unregister, deletion or forced refresh follows it. A failed
  release or relaunch remains pending. It never becomes healthy retirement.
- Recovery verifies an already-correct exact registration without forcing
  `lsregister -f` again. It can register an absent exact app/extension pair.
  During verified transaction-owned publication, it completes an app-present/extension-absent
  pair with only `pluginkit -a` for the exact extension. It does not register the app
  again. It rechecks the pair before completion and reads it back
  afterward. Extension-present/app-absent remains unsafe to force, because the
  extension may already be hosted. Partial pairs outside transaction authority
  also refuse. Errors include the exact observed pair, never hiding it.
  A durable verified commit finishes release/retention. Pre-commit failures
  still restore the previous working state. Explicit uninstall includes only
  receipt-owned retired storage, under its existing consent and idle guards.
