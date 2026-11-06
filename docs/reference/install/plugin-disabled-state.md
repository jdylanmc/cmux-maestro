# Transaction and recovery contract: plugin disabled state and recovery blocks

Part of [install, update, and recovery](../install-update-recovery.md). Previous page is [Transaction and recovery contract: integration checkpoint](integration-checkpoint.md). Next page is [Recovery commands and diagnostics](recovery-commands.md).

- Copilot 1.0.89 supports disabling direct plugins, but its install/update
  operations re-enable them. Identical repeats and compatible external-resource
  updates still skip provider mutation. Payload replacement instead records the
  prior disabled state and mutation intent durably, keeps dedicated staging
  inactive, then uses the official `plugins.disable` API and identity-checked
  readback before publication or app commit. Recovery reapplies the same choice
  before claiming restoration, including after an interruption between install
  and disable. A disabled legacy observer migrates to a disabled dedicated file.
  Native-plugin state remains separate from an already-configured dedicated
  file's choice. Direct disable is not effective on 1.0.88. Never claim it
  as a supported restoration there.
- Install and disable are separate provider operations, **not an atomic
  provider primitive**: the plugin can temporarily report enabled, and a crash
  can retain that state until recovery runs. Dedicated staging remains inactive
  throughout this interval. No success or restored-state claim is emitted
  without verification. New choices after verified apply, wrong source
  identities and unrelated changes are not overwritten. Standalone maintenance
  cannot replace a disabled native payload without the coordinated install
  checkpoint.
- The disposable-home source binding is recorded **before** real-home mutation,
  so loss of the real install response is not a name-only recovery boundary.
  Compensation independently bootstraps that same source again, checks current
  selection and prior provenance, and targets exact identity. First-install
  source files remain available until official removal succeeds, including
  across interrupted compensation. Failed bootstrap or changed foreign
  selection refuses further mutation and retains explicit recovery state.
- A surviving or unconfirmed command supervisor blocks restoration. The
  installer never races a still-running mutator. A failed restoration reports
  both errors and retains recoverable state. The durable commit decision is
  written only after both components are verified. An interruption after that
  decision finishes checkpoint/backup bookkeeping. It does not undo an already
  verified commit. Cleanup errors remain explicit. No GUI reload or existing
  chat behavior is inferred from restoring registrations.
- A committed checkpoint awaiting cleanup blocks separate preparation,
  historical rollback and uninstall until `recover` finishes bookkeeping.
  Resuming a pending rollback re-verifies previously restored integration
  before changing the app. A concurrent user change cannot hide behind a
  saved `restored` phase. Malformed false-shaped checkpoint identities are
  rejected, not interpreted as legacy app-only state.
