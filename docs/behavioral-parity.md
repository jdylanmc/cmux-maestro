# Behavioral parity and proof

These pages map each legacy-visible capability to native regression evidence,
an intentional difference or an explicit acceptance limit. They do not claim
every synthetic edge case was reproduced on the desktop.

The native runtime, history, attention, layout, local installation and icon-led
presentation merged in [PR26][r26], [PR27][r27], [PR28][r28], [PR29][r29],
[PR30][r30] and [PR32][r32], and update preparation in [PR33][r33]. Their
public acceptance records keep local tests, actual CMUX interaction and
operational limits apart. The installed app uses the stable Applications
location.

## Run the behavioral suite

```sh
./scripts/test.sh
```

This runs the Swift behavioral tests and builds their preference fixture
client, with no new test framework. The [CI workflow](../.github/workflows/ci.yml)
also runs build metadata, installer transaction, SDK-fetch concurrency,
compiled-hook and sandbox checks. Validation hosts do not open installation
windows or permit plugin changes.

### Background-shell representation

[Background-shell representation](behavioral-parity/background-shell.md)

### Setup fixture readiness

[Setup fixture readiness](behavioral-parity/setup-fixture-readiness.md) | [Hosted integrated runner](behavioral-parity/hosted-integrated-runner.md)

### Explicit owned-descendant and subtree close (#90, #91, #377)

[Owned-descendant and subtree close](behavioral-parity/owned-descendant-close.md)

### Dedicated observer registration (#114)

[Observer registration](behavioral-parity/observer-registration.md) | [Provider probe evidence](behavioral-parity/observer-provider-probes.md) | [Migration and restoration](behavioral-parity/observer-migration.md)

### Coordinated alpha installation (#114)

[Coordinated alpha installation](behavioral-parity/alpha-installation.md) | [Retired slots and native publication](behavioral-parity/install-retired-slots.md) | [Integration checkpoint](behavioral-parity/install-integration-checkpoint.md) | [Plugin identity and disabled state](behavioral-parity/install-plugin-state.md) | [Plugin-state recovery and tests](behavioral-parity/install-plugin-recovery.md)

### Direct interactive launch and legacy startup (#61)

[Direct interactive launch](behavioral-parity/direct-interactive-launch.md) | [Legacy fixtures and lock budgets](behavioral-parity/launch-legacy-fixtures.md) | [Workspace capacity](behavioral-parity/launch-workspace-capacity.md) | [Native-child permissions](behavioral-parity/launch-child-permissions.md) | [Launch model selection](behavioral-parity/launch-model-selection.md)

### Deep-outline fixture readiness

[Deep-outline fixture readiness](behavioral-parity/deep-outline-fixtures.md)

## Managed Git provenance

[Managed Git provenance](behavioral-parity/managed-git-provenance.md)

## Lazy preference observation (#169)

[Lazy preference observation](behavioral-parity/lazy-preference-observation.md)

## Capability matrix

[Capability matrix](behavioral-parity/capability-matrix.md): each visible capability with its native proof and runtime evidence.

### Bounded oversized event projection

[Bounded oversized event projection](behavioral-parity/oversized-event-projection.md)

### Multi-turn child identity and completion attribution

[Multi-turn child identity](behavioral-parity/multi-turn-child-identity.md) | [Unknown turns and capability](behavioral-parity/multi-turn-unknown-and-capability.md)

## Intentional differences and explicit limits

[Intentional differences and explicit limits](behavioral-parity/intentional-differences.md): superseded proposals, deliberate gaps and acceptance boundaries.

[r26]: https://github.com/jdylanmc/cmux-maestro/pull/26
[r27]: https://github.com/jdylanmc/cmux-maestro/pull/27#issuecomment-5658114796
[r28]: https://github.com/jdylanmc/cmux-maestro/pull/28#issuecomment-5659682603
[r29]: https://github.com/jdylanmc/cmux-maestro/pull/29#issuecomment-5660229219
[r30]: https://github.com/jdylanmc/cmux-maestro/pull/30#issuecomment-5661185922
[r32]: https://github.com/jdylanmc/cmux-maestro/pull/32#issuecomment-5662015261
[r33]: https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270
