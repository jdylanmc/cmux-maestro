# Copilot refresh and same-build updates

[↑ Install, update, and recovery](../install-update-recovery.md) | [← Update, rollback and status](update-and-rollback.md) | [Transaction and recovery contract: locks and supervision →](transaction-contract.md)

Normal install/update refresh Copilot in the same transaction. The historical
explicit `rollback` command keeps its app-only compatibility behavior for
older backups, including versions without the new bridge. It differs from
automatic combined failure recovery. It may require explicit integration
maintenance afterward.
The stock host's identity-disappearance/reappearance behavior motivates the
automatic registration transition. Mocked registry tests do not establish
real loaded-generation or focus-preservation acceptance.

Updates may replace a changed development build with the same build number.
They never silently downgrade. `install` also upgrades an existing receipt-owned
app in place. Manual uninstall is not required. An identical artifact verifies
the app, exact registration, owned integration resources and public provider
state. A fully current repeat skips app/resource replacement and plugin mutation.
If only integration needs repair, the same command performs a journaled
integration refresh without exchanging the app. It does not require idleness, since no
executable is replaced. Missing registration or altered app contents still
refuse. They never pass as a verified no-op. Explicit development-source
retirement still applies when requested.
Rollback revalidates the previous app's **own** matching app/extension
version, strict signatures, production identities and compatible entitlements.
Receipt-owned historical ad-hoc previews remain valid for status/recovery/rollback,
not new publication. Provisioned receipts also revalidate their embedded profile
and signer. Expired or mismatched profiles refuse rather than bypassing OS policy.
A previous preview with fewer approved read-only grants is
allowed. Missing sandbox, broader or unknown grants, unsigned components and
test namespaces are refused. Normal publication/install validation still
requires the current build number. This feature does not bump it.
