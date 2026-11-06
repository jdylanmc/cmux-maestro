# Setup controls and focused diagnostics

Part of [Build and test](../build-and-test.md). Previous page is [Watchdog report slots](watchdog-report-slots.md). Next page is [Validation builds](validation-builds.md).

`test-copilot-setup.sh` also runs disposable Foundation-only controls: successful
disarming, stalled injected clock, continued polling of frozen clock, and
a real stuck sampler that writes partial output before ignoring termination.
Both stalled controls must fail with sampled actual-runner stacks. Unexpected
return, missing stack or outer probe timeout fails validation. Sampler-fault
control must fail after killing and reaping its exact child while preserving
partial output. It does not stand in for real stack-collection acceptance.
Three additional finite fake-sampler controls distinguish exit 17 without output,
exit 17 with output, and timeout without output. Missing-file controls require
both original process outcome and explicit sample-read failure.
Additional finite controls distinguish living, exited-but-unreaped, and returned/reaped
child contexts from outer task completing. Changed-start and truncated-group
controls query only newly owned fixture processes and must retain unknown states.
Every stalled control still exits 124. Successful disarming still exits zero.
Three synthetic no-metadata-child controls exercise cancellation pending,
cancellation returned with execute still pending, and held observation lock.
They require bounded persisted diagnostics and original exit 124, not
successful cancellation or reproduced native hang. Focused non-UI checks:

```sh
./scripts/test-copilot-setup.sh --compile-only
.build/setup-tests/setup-tests --filter CopilotSetupObservationTests
python3 scripts/test-metadata-watchdog.py \
  --probe .build/setup-tests/metadata-watchdog-probe \
  --results-root .build/setup-tests/metadata-watchdog \
  --mode diagnostic-cancel-pending --mode diagnostic-cancel-returned \
  --mode diagnostic-lock-held
```

Navigation response-ordering fixtures inject a cancellation-aware,
non-expiring deadline through connection model's navigation dependency.
Unrelated hosted main-actor delays must not turn those ordering checks into a
wall-clock timeout test. Separate injected-deadline control requires timeout
and rejection of late host success. Existing real-delay timeout test remains.
Default connection construction still uses the unchanged ten-second production
deadline.

Focused history/preference diagnostics after building validation products
(not a full-suite pass):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CMUXMaestroPreview.xcodeproj -scheme CMUXMaestroPreview \
  -configuration Debug -derivedDataPath .build/tests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CMUX_BUNDLE_ID_SUFFIX=.Validation.Tests \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_VALIDATION' \
  CMUX_SIDEBAR_EXTENSION_POINT_ID=com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar \
  test-without-building \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferencesTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryPollingTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferenceCoordinationTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionCoordinationTests
```

Test runner compiles a fixture-only client from production preference
sources. Tests inject unique defaults suites and files beneath
`.build/preference-coordination/`. They never mutate production preferences.
File-I/O-heavy preference suites serialize independent cases and yield between
fixture phases. This stops synchronous coordination starving unrelated UI timers.
Dedicated coordination tests still exercise simultaneously blocked writers in
separate processes and automatic observation, without manual refresh.
