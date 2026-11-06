# Recovery commands and diagnostics

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Transaction and recovery contract: plugin disabled state and recovery blocks](plugin-disabled-state.md) | [Remove only the owned local preview →](remove-local-preview.md)

```sh
python3 scripts/local-preview.py status
python3 scripts/local-preview.py recover

# Recover interrupted replacement by restoring its previous app (or absence):
python3 scripts/local-preview.py recover --restore-previous
```

For coordinated installs with retained source authority, recovery restores both prior components whenever the
app receipt still records a pending transaction, including after the app was
already exchanged. Older app-only journals keep their finish-forward
recovery behavior. Recovery can
resume its own interrupted cleanup or rollback. If no transaction is pending,
it verifies owned apps and refreshes the stable registration. A new explicit
`install`/`update` first restores any interrupted install's prior app state
before staging its requested artifact. It does not silently finish that
interrupted combined install.
`recover --restore-previous` restores absence after an interrupted first install.
Recovery refuses ambiguous identities, replaced partial-cleanup directories, foreign backups,
and corrupt receipts. It never guesses or deletes them. Preserve the
receipt, apps and original checkout/source while a transaction is pending.
Do not manually shuffle slots or remove metadata to force an update.

When exact LaunchServices verification fails, the error includes one JSON
diagnostic: the operation (`verify`, `register`, `unregister`, `ensure-existing`
or `ensure-completed`), installer stage, transaction kind/phase, bundle ID, exact
target, and expected/observed presence. A failed query reports `observed: unknown`
and its exception class, never verified absence. The diagnostic uses the same
query result as the guard. It does not requery, dump registry contents or list
other application paths. Target strings are JSON-escaped. Direct adapter checks
without installer context report null stage/transaction/phase.

These diagnostics identify the failing check, not its cause or an installation
repair (#185). They cover the LaunchServices check in `verify_registration`.
Earlier mutation/query failures and extension verification keep their existing
errors. Automatic restoration preserves the original diagnostic. If restoration
also fails, both failures remain in the error and the journal remains available.
Preserve the complete failure output. Successful later `status` verification
does not establish why the original installation failed. A new live installation
or recovery still requires its own authorization. Diagnostics add no retry.

Only an existing, normal, non-root user's real home is used. `HOME` overrides
are not install roots. Symlink components, foreign ownership, group/world
writable paths, escaping bundle symlinks and hard-linked files are refused.
Internal relative framework symlinks are allowed. Specify an alternate destination
**before** the command. It must be a direct `.app` child of the
same `~/Applications`, for example:

```sh
python3 scripts/local-preview.py \
  --destination "$HOME/Applications/My Maestro Preview.app" install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app"
```

The singleton receipt binds that destination. Use the same option thereafter.
No automatic adoption, relocation or force-overwrite mode exists, even for
another apparently matching Maestro app. Ad-hoc signatures establish local
integrity and component identity, **not publisher authenticity**: choose a
trusted source. This is not protection against another process already
controlling your user account or machine.
