# When to revisit, and a coherent future design

Part of [CI setup reuse](../ci-setup-reuse.md). Previous page is [Rejected options](rejected-options.md).

Reconsider DerivedData reuse only when a live A/B test on hosted runners (cold
miss against warm hit, same commit) shows a net saving of at least 2 minutes
on the critical path after restore. That is likely only if one of these is
true:

- `build-for-testing` grows beyond about 6 minutes;
- Xcode's compilation cache becomes reusable across DerivedData locations;
- the project moves to persistent or self-hosted runners, where DerivedData
  survives without transfer.

### A coherent future design

- **Exact key, no fallback.** Hash `xcodebuild -version`, the SDK build, the
  architecture, the `test.sh` settings array, `project.pbxproj` and the scheme.
  Do not key on source: a source key would never hit on pull requests. Do not
  use `restore-keys`: partial matches would cross toolchains or settings.
- **Source is recorded, not keyed.** Write the producing commit and key fields
  into a manifest inside the entry and log them on restore. Xcode's own input
  tracking decides what to rebuild. After checkout every Swift file is newer,
  so only PCMs and planning are reused.
- **Validate before use.** If the manifest is missing or its key fields differ
  from the current values, delete the restored directory and build cold. Log
  hit, miss or rejection.
- **Restore before the build, never in place of it.** Delete `Build/Products`
  before building. Run every test as now.
- **Save only from `main`.** Pull requests restore `main`'s entry for the same
  toolchain and project file. A pull request that changes either misses and
  builds cold.
- **Namespaces stay separate.** Only `.build/tests` is restored; never
  `.build/unsigned`, the guide DerivedData, results or evidence.
- **Guard change required.** The guard in
  `scripts/test-build-metadata.py` forbids every part of this today. It
  must change in the same commit, together with the merge policy and this page.
