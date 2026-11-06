# Alpha installation: plugin identity and disabled state

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Integration checkpoint](install-integration-checkpoint.md) | [Alpha installation: plugin-state recovery and tests →](install-plugin-recovery.md)

Plugin mutations use public sessionless RPCs, with the supported status checked
before the mutation request. An install receipt supplies the exact owned
`directSourceId`. Later discovery must match. Removal and compensation target
that identity, not only the manifest name. Even a receipt followed by a failing
provider-process exit is retained for recovery. Independent bootstrap records
the same source's identity before real-home mutation, so a lost production
response can still be compensated without adopting a name-only list row.
Recovery bootstraps again and checks current selection before effects; source
files remain until exact-ID removal succeeds. Failed bootstrap and foreign
identity drift do not grant compensation authority.

The pinned [1.0.89 changelog](https://github.com/github/copilot-cli/blob/8dfa6009c4a04b3a22a5ca4a7c36a056edd718dd/changelog.md)
supersedes the SDK comments claiming direct installs are always enabled.
Disposable official-provider probes confirm direct disable/enable, zero
discovered plugin hooks while disabled, and re-enabling on both install and
update. The installer preserves a verified disabled native plugin without
provider mutation for no-ops and compatible external-resource-only updates.
For a required payload replacement it records original state and mutation
intent before the official operation, keeps dedicated staging inactive, and
requires official `plugins.disable` plus exact-source readback before
publication/commit. The disable RPC is attempted on stable 1.x releases using
protocol 3 and checks the selected identity before its name-based mutation.
Unsupported operations or failed disabled-state readback still block publication.
Install/update success alone
does not prove preservation. Disabled legacy observer migration also disables
the dedicated file. An existing dedicated file retains its independent choice.
