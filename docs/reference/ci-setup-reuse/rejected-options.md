# Rejected options

[↑ CI setup reuse](../ci-setup-reuse.md) | [← Interpretation](interpretation.md) | [When to revisit, and a coherent future design →](when-to-revisit.md)

| Option | Reason |
| --- | --- |
| Cache the test build's DerivedData | Projected net saving of about 10 to 95s, below the 2-minute threshold and within run-to-run noise. Restored `Build/Products` keeps resources and binaries the project no longer produces, so it must be dropped. Correctness then rests on Xcode's incremental state across Xcode or runner-image updates. Hosted macOS images update Xcode builds without notice, so the key must include `xcodebuild -version`, the SDK build, the architecture, the settings and the project file. Saving entries of about 170 MB from every pull request would churn the 10 GB repository cache, so saving would be limited to `main`. |
| Cache only precompiled SDK modules (`SDKExplicitPrecompiledModules`, `ModuleCache.noindex`) | No measured gain. Xcode regenerated every PCM without the matching `Build/Intermediates.noindex`. |
| Xcode compilation cache (`CompilationCache.noindex`) | No measured gain when restored into new DerivedData. It adds 558 MB and changes the test namespace's build settings. |
| Cache the pinned SDK checkout | Fetches take 3 to 12s, so a cache restore would not be faster. The pin already binds the source. |
| Share one build between `test.sh` and `build-unsigned.sh` | Breaks the distinct namespace guarantee: one configuration's success would prove the other. |
| Reuse the unsigned build or the guide probe build in the native job | Guide acceptance must own fresh, invocation-specific evidence and exact source attribution (`run-guide-ui-validation.py` hashes its inputs). |
| #195 handoff: reuse the test build (`.build/tests`) or the setup-tests build for guide acceptance | **Rejected.** The guide build is a different configuration: its own scheme, `CMUX_GUIDE_UI_VALIDATION` instead of `CMUX_VALIDATION`, its own bundle identifiers and no namespace suffixes. The setup-tests build is a `swiftc` command-line binary, not an Xcode app and UI-test bundle. Only PCMs could be shared, and restoring modules alone gave no gain. Its compile phase is 40 to 51s. The 2m03s to 2m24s probe execution dominates and cannot be reused. A fresh DerivedData is part of its attribution. |
| #195 handoff: share the preview bridge compile with `test-copilot-setup.sh` | **Rejected.** The bridge is `test-copilot-setup.sh --compile-only`, which adds `CLIIntegrationGuideRenderingTests.swift` and `GuideAcceptanceEvidence.swift`. Reusing one build for both would change the setup binary's tested source set or couple two suites through mutable `.build/setup-tests` state. At most 18 to 29s would be saved in `validate-contracts`, which is not the critical path. |
| Cache `test-copilot-setup.sh`, preference-client or hook binaries keyed by source hash | These are test executables whose inputs change in most pull requests. They save at most about 50s, all of it in `validate-contracts`, which finishes before `validate-native`. |
| Reuse test results, `.xcresult` bundles, receipts or screenshots | Never acceptable as proof of a new invocation (#193, #190). |
