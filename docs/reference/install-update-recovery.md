# Install, update, and recovery

How to install, update, roll back, recover and remove the stable local preview,
and the transaction contract behind those commands. Short version:
[README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Install a stable local preview

Build and install the development-signed alpha from a trusted checkout. See
[install a stable local preview](install/local-preview.md) and
[install a verified artifact](install/verified-artifact.md).

### Update, rollback and status

Updates journal, verify and replace the app and its Copilot integration
together. See [update, rollback and status](install/update-and-rollback.md) and
[Copilot refresh and same-build updates](install/copilot-refresh.md).

### Transaction and recovery contract

- [Locks and supervision](install/transaction-contract.md): the owned hooks
  file, the install lock, progress markers and the command timeout.
- [Integrity and retained generations](install/retained-generations.md): the
  integrity receipt and the previous and retired app slots.
- [Integration checkpoint](install/integration-checkpoint.md): the private
  checkpoint and receipt journaling.
- [Plugin disabled state and recovery blocks](install/plugin-disabled-state.md):
  disabled plugin state, source binding and what blocks restoration.
- [Recovery commands and diagnostics](install/recovery-commands.md): `status`,
  `recover`, LaunchServices diagnostics and the install destination.

### Remove only the owned local preview

Uninstall the native integration first, then remove the receipt-owned app. See
[remove only the owned local preview](install/remove-local-preview.md).
