# Local preview suite, Swift tests and next steps

Part of [test performance](../test-performance.md). Previous page is [Orchestrator suite evidence](orchestrator-evidence.md).

## Local preview suite

### Local preview profile

Local run (load 12 to 15, 245.7 s, 124 tests):

- The compiled install bridge (`test-copilot-setup.sh --compile-only`) takes
  18 to 29 s, once per suite. Reusing it across suites belongs to #193.
- The gated-provider bridge-death test (36 s, four subcases) spends about 30 s
  waiting for its child installer to reach the gated provider. That is the real
  install transaction in a child process.
- In-process transaction tests are file-system bound. One registration-restore
  test spent 3.4 s of 13.3 s in 76 receipt `os.replace` calls after `fsync`,
  3.1 s copying fixture app trees and 3.3 s in 2,005 synthetic command calls.
- Poll intervals are already 15 to 25 ms under unchanged deadlines.

### Local preview changes

None. The dominant costs are durable writes, real child processes and the
bridge compile that the tests exist to exercise. Replacing `fsync`, renames or
processes would mock the transaction under test.

## Swift tests

### Swift profile

From run 38662873916's `test.sh` log:

- Reported `passed after` times are not work. Most AppKit-scoped tests report
  190 to 230 s because they include waiting on the shared AppKit gate.
- The gate's `R3 AppKit scope begin/end` markers sum to 325.5 s of gated body
  time across 329 cases in a 345.1 s span, so the gate serializes nearly the
  whole 352.6 s run. 123 markers interleave, so per-test values are diagnostic
  samples.
- Largest gated bodies: `targetLedNativeComposition()` 38.8 s;
  `activeWindowFooterLeavesUsableOutlineAtShortAndNarrowSizes()` 21.0 s;
  `directoryProvenanceRendersInProductionHoverPinnedAndDetails(dark:)` 20.7 s
  (2 cases); `inspectorRenderEvidenceRejectsWrongMissingHiddenAndClippedModels(dark:)`
  20.4 s (2 cases); `titleAndFixedNativeActionGroup(dark:width:)` 14.3 s
  (8 cases); `focusAcknowledgesExactAttentionOnlyAfterNavigationSucceeds(mode:succeeds:)`
  13.5 s (4 cases).

### Swift changes

None. Changing gated Swift fixtures needs a profile of rendering, text
recognition and pixel conversion inside those tests first, and full `test.sh`
before/after runs on a quiet machine.

## Recommended next steps

1. **Gated Swift bodies.** Instrument the six largest gated tests with
   `ContinuousClock` around render, text recognition and pixel conversion, then
   cache repeated bitmap conversions within one case. Keep light/dark, density,
   geometry and negative controls.
2. **Guide acceptance (~104 s in `test.sh`).** Measure its compile and run
   phases separately. Reuse with the setup-tests build belongs to #193.
3. **Preview bridge compile (18 to 29 s).** Share it with
   `test-copilot-setup.sh`'s build in the same job (#193), keeping source
   provenance.
4. **Orchestrator harness setup (~0.7 s × 144).** A cheaper registration
   fixture would need evidence that no test depends on the real `register`
   path. Not done.
5. **Preview file-system cost.** Measure `fsync` and `os.replace` cost on the CI
   runner before considering any change. Durability is the tested contract.
