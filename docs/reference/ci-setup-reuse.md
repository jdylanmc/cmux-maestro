# CI setup reuse

Issue #193 asked whether CI can reuse expensive setup without weakening
isolation. **Decision: no cross-run reuse for now.** No setup state is cached
or restored between runs, and every job builds from a clean checkout.

`scripts/test-build-metadata.py`
(`test_ci_reuses_no_setup_state_across_runs`) enforces the boundary. The
workflow may use only `actions/checkout` and `actions/upload-artifact`. Any
new action, even one with no cache such as `actions/setup-python`, needs a
setup-reuse review and a guard update. The guard parses every `uses:` line,
including quoted and comment-suffixed ones, and fails if any is unparsed. The
workflow may not contain `actions/cache`, `restore-keys`, `cache:`,
`cache-dependency-path`, `download-artifact`, `gh run download` or `gh cache`.
`scripts/test.sh` and `scripts/build-unsigned.sh` keep their separate
DerivedData namespaces (`.build/tests` and `.build/unsigned`). Adding reuse means re-measuring it and updating this page and that guard
together.

## Inventory

[Inventory: sources and validate-native](ci-setup-reuse/inventory.md)

### Sources

[Sources](ci-setup-reuse/inventory.md#sources)

### `validate-native`: `./scripts/test.sh`

[`validate-native`: `./scripts/test.sh`](ci-setup-reuse/inventory.md#validate-native-scriptstestsh)

### `validate-contracts`

[Inventory: other suites and existing reuse](ci-setup-reuse/validate-contracts.md)

### `guide-ui-consumer-probe`

[`guide-ui-consumer-probe`](ci-setup-reuse/validate-contracts.md#guide-ui-consumer-probe)

### Existing reuse within a run

[Existing reuse within a run](ci-setup-reuse/validate-contracts.md#existing-reuse-within-a-run)

### Configurations that are not repetition

[Configurations that are not repetition](ci-setup-reuse/validate-contracts.md#configurations-that-are-not-repetition)

## Measured cost and benefit of the realistic candidate

[Measured cost and benefit of the realistic candidate](ci-setup-reuse/measured-cost-and-benefit-of-the.md)

### Method

[Method](ci-setup-reuse/measured-cost-and-benefit-of-the.md#method)

### Results

[Results](ci-setup-reuse/measured-cost-and-benefit-of-the.md#results)

### Interpretation

[Interpretation](ci-setup-reuse/interpretation.md)

## Rejected options

[Rejected options](ci-setup-reuse/rejected-options.md)

## When to revisit

[When to revisit, and a coherent future design](ci-setup-reuse/when-to-revisit.md)

### A coherent future design

[A coherent future design](ci-setup-reuse/when-to-revisit.md#a-coherent-future-design)
