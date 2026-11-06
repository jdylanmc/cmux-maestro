# Explicit local-only native acceptance

[↑ Required CI and local acceptance](../ci-test-determinism.md) | [← Installer, preferences and guide acceptance](installer-preferences-and-guide-acceptance.md) | [Repeated focused diagnostics and timing ratchet →](repeated-focused-diagnostics.md)

`scripts/local-ui-acceptance.json` inventories each opt-in test and its reason.
The same identities appear as attributed skips in `coverage.json`; an unlisted
skip, missing inventory entry, or enabled test that skips still fails validation.
No test body, pixel tolerance, focus oracle, or negative control is weakened.

The local cases include native animation sampling,
OCR or hosted view discovery. They are useful manual
acceptance probes but cannot be mandatory evidence from an uncontrolled runner.
Pure phase/reduced-motion, key-chain, layout-budget, retention/dismissal-identity,
and form-state tests remain required. This is a deliberate reduction of *native
venue* guarantees at the merge gate, not a claim the venue tests were repaired.
The key-window test and all six viewport positive/negative controls remain
required: no failures for them were established in the mined history. #127's runtime mechanism is not declared solved. #174's cancellation stall was already removed by an earlier owner decision and remains unresolved.

The #307 mounted-sidebar probe is also opt-in: it observes real display cycles with
synthetic idle or working/input rows, enabled pets and frozen poll inputs. Two
half-second run-loop windows expose continuing layout, not a required runner-speed
budget. The root layout count must remain unchanged during the second window.
Required tests separately cover compositor frame/state changes, hide/detach cleanup,
Reduce Motion and stat-only unchanged event-file reads. A passing offscreen probe
does not establish the installed ExtensionKit process's CPU use.

The #316 native-motion probe orders a small synthetic window without activating
the app. It renders that window's live **presentation** layer tree into local
PNGs and checks advancing rotation/glow/pet-frame properties. `cacheDisplay`
of a hidden window only records model state and cannot observe Core Animation
motion. Positive pixel changes remain confined to the status/pet lane; text
and all Reduce Motion controls must remain exactly unchanged in every sample.
Three fixed samples, separated by 250 ms then 370 ms after initial setup, avoid
relying on one pair that can alias a rotation or straddle a pulse peak. Any
pairwise lane/property difference proves motion; no elapsed time is asserted
and no failed test is retried. Actual native scheduling remains venue-dependent.
The idle pet uses
a synthetic six-frame sequence through the production pet view/store.
Required tests separately check attached animation configuration and preservation
of phase across unchanged updates/layout, without advancing wall time.
This explicitly on-screen, opt-in exception does not change the offscreen
critical-text oracles in ADR 0019. It records no desktop or other application's
content and requires no screen-recording grant. Presentation-tree rendering is
not a WindowServer screenshot, installed sidebar acceptance, or CPU evidence.
Direct ScreenCaptureKit capture also requires human-granted permission;
its absence must not be reported as successful compositor capture.

Run specific acceptance methods locally without changing global preferences:

```sh
CMUX_MAESTRO_LOCAL_UI_ACCEPTANCE=1 ./scripts/test.sh \
  --focused 'SidebarMotionTests/nativeMotionAndStaticNegativeControlsStayInsideTheStatusLane()'
CMUX_MAESTRO_LOCAL_PROCESS_ACCEPTANCE=1 python3 scripts/test-cmux-maestro-orchestrator.py \
  OrchestratorTests.test_git_counts_cover_net_head_changes_untracked_binary_and_refresh
```

The Git test requires real commands to finish within the unchanged production
one-second probe deadline. Required deterministic tests exercise the exact
net-versus-HEAD query arguments and parse text, binary, untracked, rename and
clean results without scheduling real Git. Parser rejection tests also stay required; successful
real Git collection is local acceptance, not a promise about runner speed.
Native local acceptance can require an interactive graphical session; use a
disposable validation venue, not a live Maestro installation.
