# Repeated focused diagnostics and timing ratchet

[↑ Required CI and local acceptance](../ci-test-determinism.md) | [← Explicit local-only native acceptance](explicit-local-only-native-acceptance.md) | [Elapsed-time audit (#310) →](elapsed-time-audit.md)

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
the dependency. Do not regenerate the baseline to silence a failure. This
lightweight lexical check is not a Swift/Python dataflow proof and does not
replace review of clocks hidden behind helpers.
