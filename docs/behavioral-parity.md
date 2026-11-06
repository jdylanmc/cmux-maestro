# Behavioral parity and proof

These pages map the legacy-visible capability inventory to native regression
evidence, intentional differences, or explicit acceptance limits. They do not
claim that every synthetic edge case was reproduced on the desktop.

The native runtime, history, attention, layout, local installation and icon-led
presentation are merged in [PR26][r26], [PR27][r27], [PR28][r28], [PR29][r29],
[PR30][r30] and [PR32][r32]. Update preparation in [PR33][r33] is also merged.
Their public acceptance records keep local tests, actual CMUX interaction and
operational limits apart. The installed app uses the stable Applications
location.

## Run the behavioral suite

```sh
./scripts/test.sh
```

This runs the Swift behavioral tests and builds their existing preference
fixture client. The [CI workflow](../.github/workflows/ci.yml) also runs build
metadata, installer transactions, SDK-fetch concurrency, compiled-hook and
sandbox checks. Validation hosts do not open installation windows or permit
plugin changes. The suite needs no new test framework.

### Background-shell representation

Shell notifications stay decoded but no longer create work rows or attention.
See [background-shell representation](behavioral-parity/background-shell.md).

### Setup fixture readiness

Process-cleanup tests wait for the first post-spawn sample before arming the
readiness watchdog. See [setup fixture readiness](behavioral-parity/setup-fixture-readiness.md)
and the [hosted integrated runner](behavioral-parity/hosted-integrated-runner.md).

### Explicit owned-descendant and subtree close (#90, #91, #377)

`maestro_close` admits one exact owned descendant, or an explicit subtree, and
requests one stock host close. See
[owned-descendant and subtree close](behavioral-parity/owned-descendant-close.md).

### Dedicated observer registration (#114)

Explicit setup owns a dedicated version-1 observer file. See
[observer registration](behavioral-parity/observer-registration.md),
[provider probe evidence](behavioral-parity/observer-provider-probes.md) and
[migration and restoration](behavioral-parity/observer-migration.md).

### Coordinated alpha installation (#114)

The installer replaces the app, integration and registration as one recoverable
transaction. See [coordinated alpha installation](behavioral-parity/alpha-installation.md),
[retired slots and native publication](behavioral-parity/install-retired-slots.md),
[integration checkpoint](behavioral-parity/install-integration-checkpoint.md) and
[plugin identity and disabled state](behavioral-parity/install-plugin-state.md)
and [plugin-state recovery and tests](behavioral-parity/install-plugin-recovery.md).

### Direct interactive launch and legacy startup (#61)

New interactive roots and children exec Copilot directly. See
[direct interactive launch](behavioral-parity/direct-interactive-launch.md),
[legacy fixtures and lock budgets](behavioral-parity/launch-legacy-fixtures.md),
[workspace capacity](behavioral-parity/launch-workspace-capacity.md),
[native-child permissions](behavioral-parity/launch-child-permissions.md) and
[launch model selection](behavioral-parity/launch-model-selection.md).

### Deep-outline fixture readiness

Focus-layout fixtures fix available content width, not the scroller style. See
[deep-outline fixture readiness](behavioral-parity/deep-outline-fixtures.md).

## Managed Git provenance

Managed Git labels describe the assigned directory. See
[managed Git provenance](behavioral-parity/managed-git-provenance.md).

## Lazy preference observation (#169)

Layout stays read-only and watches the nearest existing container. See
[lazy preference observation](behavioral-parity/lazy-preference-observation.md).

## Capability matrix

Each visible capability with its native proof and runtime evidence is in the
[capability matrix](behavioral-parity/capability-matrix.md).

### Bounded oversized event projection

Oversized lines keep only decoder metadata under fixed bounds. See
[bounded oversized event projection](behavioral-parity/oversized-event-projection.md).

### Multi-turn child identity and completion attribution

A multi-turn child keeps its identity across fresh interactions. See
[multi-turn child identity](behavioral-parity/multi-turn-child-identity.md) and
[unknown turns and capability](behavioral-parity/multi-turn-unknown-and-capability.md).

## Intentional differences and explicit limits

Superseded proposals, deliberate gaps and acceptance boundaries are in
[intentional differences and explicit limits](behavioral-parity/intentional-differences.md).

[r26]: https://github.com/jdylanmc/cmux-maestro/pull/26
[r27]: https://github.com/jdylanmc/cmux-maestro/pull/27#issuecomment-5658114796
[r28]: https://github.com/jdylanmc/cmux-maestro/pull/28#issuecomment-5659682603
[r29]: https://github.com/jdylanmc/cmux-maestro/pull/29#issuecomment-5660229219
[r30]: https://github.com/jdylanmc/cmux-maestro/pull/30#issuecomment-5661185922
[r32]: https://github.com/jdylanmc/cmux-maestro/pull/32#issuecomment-5662015261
[r33]: https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270
