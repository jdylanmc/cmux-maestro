# Local preview suite, Swift tests and next steps

[↑ Test performance](../test-performance.md) | [← Orchestrator suite evidence](orchestrator-evidence.md)

## Local preview suite

### Local preview changes

None. The dominant costs are durable writes, real child processes and the
bridge compile that the tests exist to exercise. Replacing `fsync`, renames or
processes would mock the transaction under test.

## Swift tests

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
