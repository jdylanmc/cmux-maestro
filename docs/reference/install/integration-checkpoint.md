# Transaction and recovery contract: integration checkpoint

Part of [install, update, and recovery](../install-update-recovery.md). Previous page is [Transaction and recovery contract: integrity and retained generations](retained-generations.md). Next page is [Transaction and recovery contract: plugin disabled state and recovery blocks](plugin-disabled-state.md).

- Before app replacement, a private `0600` checkpoint at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/install-transaction.json`
  captures the fixed owned resource set, registration provenance, prior absence,
  modes and public provider identities. It sits outside every sidebar-readable
  prefix. No sandbox grant is added. Recovery validates its schema, exact paths, file bounds and
  transaction identity first. Separate setup refuses
  while the coordinated transaction is pending.
- Every observer-receipt write records its exact permitted bytes, permissions
  and independently established source provenance in the checkpoint before
  publication. Recovery without a final `after` snapshot accepts only the
  known prior image or those bounded exact intents, never desired-generation
  equality alone. Edited plugin/source identities preserve their bytes and
  pending journal. Durable-after and resource-only enrichment checks remain
  strict. Ambiguous older interrupted checkpoints are not guessed into authority.
- The app receipt journals the companion transaction ID and its progress.
  Pending failure recovery first verifies/restores integration. It uses
  official `plugins.install` at the unchanged owned source path, or `plugins.uninstall`
  scoped by the returned `directSourceId` for prior absence. Then it restores the
  old app and registration. The install RPC receipt binds that exact source.
  Later discovery must match it. Current settings
  must still match the checkpoint's values or known CLI normalization. Unrelated
  changes are not overwritten. A failed first install restores verified absence,
  not a fictitious previous app. New journals also capture and restore the exact
  application/extension registration of an explicitly retired development
  source. Older journals without that evidence refuse to guess.
