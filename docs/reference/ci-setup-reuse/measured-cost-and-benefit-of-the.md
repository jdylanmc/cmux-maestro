# Measured cost and benefit of the realistic candidate

[↑ CI setup reuse](../ci-setup-reuse.md) | [← Inventory: other suites and existing reuse](validate-contracts.md) | [Interpretation →](interpretation.md)

DerivedData reuse is the only candidate on the critical path. The test build
takes 3 to 4 minutes of a 16 to 18 minute job.

### Method

The measurements were taken locally, so they are **not representative of CI**,
only indicative of ratios:

- Xcode 27.0 (27A266a) on Apple silicon, against Xcode 26.6 (17F113) in CI.
  Locally the build ran 297 `SwiftCompile` and 224 PCM tasks; CI runs 230 and
  213. The toolchain and task graph differ.
- `-jobs 3` approximates the 3-vCPU hosted macOS runner; the unthrottled runs
  used every core.
- The same test-namespace settings as `test.sh`, running `build-for-testing`.
- "Fresh checkout" means touching every tracked file and the SDK. This matches
  `actions/checkout`, which gives every file a new modification time.
- The machine was shared, so absolute times are noisy. Use the ratios, not the
  seconds.

### Results

| Case | Wall time | Swift compile tasks | PCM tasks |
| --- | --- | --- | --- |
| Cold, empty DerivedData | 81s (other cold runs: 41s, 46s, 59s, 124s) | 297 | 224 |
| Warm, unchanged files (ideal, unrealistic in CI) | 2s | 0 | 0 |
| Warm, fresh checkout times | 61s, 52s with `Build/Products` dropped (unthrottled: 23 to 24s against 41 to 46s cold) | 296 | 0 |
| Warm, one sidebar file edited, original times otherwise | 10s | 6 | 0 |
| Only `SDKExplicitPrecompiledModules` and `ModuleCache.noindex` restored | 48s, the same as cold | 296 | 224 |
| Only `ModuleCache.noindex` restored | no gain | 296 | 224 |
| `COMPILATION_CACHE_ENABLE_CACHING=YES`, only `CompilationCache.noindex` (558 MB) restored into new DerivedData | 57s, against 59 to 66s cold | 297 | 224 |
