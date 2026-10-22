# Required CI and local acceptance

Required tests assert state and ordering, never that a loaded macOS runner can
schedule work within a few seconds. A real-process readiness/exit bound is a
60-second **hang guard**, not the behavior being asserted. Do not add retries.
Use injected time for expiry, explicit continuations/streams for ordering, and
fixed identities when exercising deliberately tiny probabilistic replay filters.
The shared sidebar hang guard retains **both** the original 300 actor scheduling
opportunities and a 60-second minimum: expiration requires exhausting both.
A wall-only deadline had shortened the old effective bound under full-suite
contention. Injected-clock tests cover both slow and fast actor turns.

## Required behavioral coverage

- Setup supervision starts both gated children before advancing their injected
  deadlines; neither can finish early. The observer retains the MainActor versus
  detached-driver distinction. Deadline-helper tests release an explicit timeout
  signal instead of measuring elapsed wall time.
  Cleanup fixtures subscribe to unrelated-process termination before launch and
  await the buffered event after closing stdin, including when an assertion throws.
  They never call Foundation's synchronous `Process.waitUntilExit()`: a local
  reproduction of #302 sampled that call stuck in its run loop after the setup
  supervisor had already completed. The mutation-gate negative control uses the
  same bounded exit helper: repeated-suite sampling also caught its old synchronous
  wait stalled. A controlled missing-notification regression
  advances an injected deadline; a second regression delivers termination before
  cleanup starts. No cleanup coverage was removed.
  Each cleanup phase also has an executor-independent watchdog at
  `supervisedWaitLimit + 10 seconds` (currently 70 seconds), with at most five
  additional seconds for stack capture. The inner 60-second bounds retain their
  full budget and report their own diagnostics first; the watchdog is a backstop
  for non-cooperative stalls, not a shorter replacement timeout. A mutation guard
  checks the configured watchdog from the shared cleanup factory against the
  inner limit, so falling back to the metadata watchdog's 30-second default fails.
  Its phase and supervisor
  boundary records use the existing `metadata-diagnostics` artifact path. This
  backstop covers synchronous fixture work and teardown as well as async waits;
  it exits with failure, never retries or converts a stalled assertion into a pass.
- Orchestration snapshots and naming use an injected clock. Polling tests await
  publication at the existing pause boundary rather than counting scheduler yields.
  Cadence fixtures suspend until cancellation, never a 60-second accidental tick.
- Multiwindow teardown awaits a subscribed scene publication, not host-local
  connection invalidation. The shared-scene test still sends its final snapshot
  during teardown. Synthetic endpoint and publication durations distinguish XPC
  propagation from actor scheduling; these measurements are diagnostics, not
  speed assertions. Each of the two teardown tests writes five small immutable
  phase JSON files as events occur. CI always uploads them separately as
  `multiwindow-teardown-phases`, independent of xcresult export and its size cap.
  The earlier hosted failure's exported diagnostics exceeded
  the artifact cap, so they do not establish which stage stalled.
- A denied installer process-group probe is conservatively treated as present.
  Only proven absence permits recovery; a transient permission refusal cannot
  crash a completion wait or release its retained guard.
- Cross-process preference tests still exercise real locks, writes, file
  presentation, and existing observable projections. Their 60-second bounds only
  detect a missing event; no manual refresh substitutes for notification delivery.
- The replay saturation fixture fixes setup event identities before applying
  pressure. A random false positive in its one-word filter is not a product defect.
- Guide acceptance remains required. The historical missing-evidence failures
  came from producer source-attribution rejection, not lost environment
  forwarding. Raw `git cat-file commit` parents bind the exact workflow commit,
  tree and candidate. The event's base SHA may precede a merge or retarget:
  the actual first parent must equal or descend from that event base, or match
  the current base tip returned by one bounded GitHub lookup for this repository,
  PR and exact candidate. Native CI fetches complete history for ancestry checks.
  The lookup's read-only token is excluded from producer build/test environments
  and consumer forwarding. Expected/actual parents and the selected proof are
  retained even when attribution fails.
- Failed guide production stops the dependent native invocation immediately,
  retains its original diagnostic in `coverage.json`, and fails the job.
  Consumers never run with knowingly absent evidence; this is a failed
  prerequisite, not an accepted skip or reduced coverage on a passing run.
  Real-Git regressions accept an advanced or verified retargeted base and reject
  a wrong candidate or unrelated first parent. A forwarding regression verifies
  both original consumer actions receive only fresh successful-producer evidence.

## Explicit local-only native acceptance

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
required: no failures for them were established in the mined history. #127's
runtime mechanism is not declared solved. #174's cancellation stall was already removed by an
earlier owner decision and remains unresolved.

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
Direct ScreenCaptureKit capture additionally requires human-granted permission;
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

## Repeated focused diagnostics

```sh
./scripts/test.sh --focused CopilotEventReducerTests,SidebarOrchestrationTests --repeat 20
```

The checked-in script builds once and starts a fresh test invocation each time.
Every selected suite/method must execute, every run must pass, and any skip or
failure stops the command. `focused.json` records all runs and explicitly says
`requiredCoverage: false`. Focused mode refuses GitHub Actions and never replaces
the full `./scripts/test.sh` CI receipt. No failed iteration is retried.
The default command works under the system Bash 3.2 with no focused arguments.
Its full local invocation still cannot produce GitHub-hosted guide acceptance;
never spoof the venue variables to turn that refusal into passing evidence.

## Timing policy ratchet

`ci-gate` always runs `scripts/test-test-timing.py` and
`scripts/check-test-timing.py`, including documentation-only changes. The guard
scans tracked Swift, Python, JavaScript and shell test sources for sleeps, wall
clock reads/comparisons, OCR and key-window dependence. New files, changed
statements, and additional copies of an existing statement fail. Multiline calls
include their balanced argument lists, including continuation-line delays.
Line numbers
and indentation do not affect the comparison.
Removed statements, excess exception counts and missing test files must remove
their old exceptions too. Test helpers under `scripts/test-fixtures/` and
installed skill `tests/` directories are included.
Shell sleeps are also detected after control words, negation, grouping and
command substitution, including backslash-continued delays; changing their delay
requires a new reviewed exception.

`scripts/test-timing-allowlist.json` freezes existing occurrences, including
real-process hang guards, fake-provider delays, offscreen native settlement,
benchmark measurements and explicit local acceptance. This is a baseline
ratchet, **not** proof all legacy timing code is deterministic. Any exception
addition needs a specific justification and independent review. Prefer removing
the dependency; do not regenerate the baseline to silence a failure. This
lightweight lexical check is not a Swift/Python dataflow proof and does not
replace review of clocks hidden behind helpers.
