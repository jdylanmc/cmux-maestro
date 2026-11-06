# Alpha installation: plugin-state recovery and tests

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Alpha installation: plugin identity and disabled state](install-plugin-state.md)

If a disable response is lost or fails, or the process exits between the
operations in [plugin identity and disabled state](install-plugin-state.md),
recovery uses the durable intent, independently re-established source authority
and official disabled-state restoration. Exact prior cache/source and settings
are verified before the app rollback completes. An intact prior payload is not
reinstalled. No private enablement key is guessed or edited. User re-enablement
after verified apply, and foreign identity drift, refuse instead of being
cleared. These are separate provider operations: the intermediate enabled state
is real, and these docs do not call it atomic suppression. Local tests cover
that boundary without executing hooks or restarting sessions; actual stock-host
and installed-session gates remain separate.

The Python suite runs the compiled Swift bridge in separate processes over real
disposable files: success, no-op, upgrade, late failure, first absence and a
real installer-process exit after apply, after which a fresh installer recovers
both generations from disk. These tests use a provider double and synthetic
registries and do not prove real stock-host reload. Another real process-exit
case stops between integration restoration and the app exchange: resumed
recovery refuses a later foreign edit, then completes once the fixture restores
the verified input. Pending committed checkpoint cleanup blocks legacy
maintenance mutations, and false-shaped receipt fields cannot bypass
coordination.

The Swift checkpoint suite separately covers stable-source compensation,
disabled legacy restoration, repeated recovery, arbitrary-path refusal and
concurrent-write controls. The focused test script's compile-only mode builds
that non-UI fixture, and its normal CI command still runs every existing test.
Current eleven-command hosted CI, source-binding resolution, native lifecycle
proof and later installed fresh-session acceptance remain separate gates.

[CopilotObserverRegistrationTests](../../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)
cover isolated registration, migration, exact event/wrapper content, preserved
disables, unavailable-key refusal, unsafe/foreign/modified state, interrupted
phases, retry, concurrent replacement, metadata and owned removal. Existing
setup cleanup tests keep their original deadlines, negative controls and
unrelated-process assertions. Complete CI, independent review and any later
production/live acceptance remain separate candidate gates.

Metadata cancellation fixtures publish the completed PID marker by same-folder
rename, not by file existence before `printf` finishes. A gate-controlled
negative control shows the old empty-marker window; the atomic case cannot
expose it. Error and cancellation paths join the owned task before deleting its
fixtures.
