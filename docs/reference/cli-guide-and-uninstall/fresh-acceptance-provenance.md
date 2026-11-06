# Fresh acceptance provenance

Part of [CLI guide, enable, and uninstall](../cli-guide-and-uninstall.md). Previous page is [Acceptance composition and runner](acceptance-composition-and-runner.md). Next page is [Guide UI consumer probe](guide-ui-consumer-probe.md).

Fresh acceptance requires clean source before and after execution, exact source
inventory/hashes, built product namespaces/hashes, attributable push or PR
synthetic-merge parents, exact native identities/counts/exits, ordered complete
stages, original validator/control executions and all 48 image provenance/hashes.
Parent provenance comes from the exact checkout commit's raw Git object, with
replacement objects disabled and its tree cross-checked. This works at a
depth-one boundary where revision traversal suppresses parents. PR parent order
must still equal the actual event's base then candidate, never event data alone.
Integrated runner disables Python bytecode writes before importing its guide
producer, so loading validation helpers cannot dirty the source checkout.
Preview-test child processes apply the same policy before importing their test
fixtures, preserving source cleanliness across the preceding CI steps.
Clean-source gate still rejects existing untracked or modified files.
Native attachment timestamps must be nondecreasing in required stage-ordinal
order through the final attachment. Equal-resolution timestamps are valid.
Guide receipt schema 2 binds the existing split-debug host layout: the host
executable, its `.debug.dylib` implementation and `__preview.dylib`, plus the
runner and test-bundle executables. Resolved host must have
`ENABLE_DEBUG_DYLIB=YES`. Validation does not change that build setting.
Each code file has an exact bundle-relative path and SHA-256, checked before
and after native acceptance and again after integrated validation. Missing,
changed, symlink-redirected or extra code in these `Contents/MacOS` directories
fails closed. This bounded inventory does not hash SDK/system frameworks.
Old executable-only receipts cannot be upgraded or reused for acceptance.
Identical legitimate pixel hashes are allowed. Failed native production still
runs the integrated suite. Missing evidence fails the original validators.
Both attachment exports are attempted and retained, but either nonzero exit
rejects acceptance even when exported files otherwise look complete.
Each exporter uses its supported default schema, not a version spelling
that differs across Xcode releases. The exact test URL selector and strict
manifest, payload, identity and timestamp checks remain mandatory. An unknown
output shape fails, without a schema retry or fallback.
Existing integrated artifact retains the producer logs, xcresult and images.
Original image artifact receives only the freshly verified guide images.
Compilation and mocked parser negatives do **not** verify native AXPress
capability or the complete matrix. Those remain unverified until reviewed
exact-source hosted execution passes.
