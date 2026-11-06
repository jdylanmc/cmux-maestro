# Orchestrator suite

Part of [test performance](../test-performance.md). Previous page is [Sources and separating the costs](sources.md). Next page is [Orchestrator suite evidence](orchestrator-evidence.md).

## Orchestrator profile

Baseline local run (load 15 to 21, 909 s, 144 tests). Five tests that fill or
hold the 32-slot live-resource budget took 328 s: three launched 30 to 31 real
fixture workers one at a time and waited for each, two held 31 pending
launches.

After #195, the default 32-slot fill is still exercised by pending and completing
workers (`test_pending_launches_hold_all_live_resource_slots`), but no test keeps 31
idle workers writing the shared state file at once. Lock waits sized for that load
(`with_store`, `MAX_LIVE_WORKERS / 8`) are no longer stressed by idle workers.

Per-process costs, measured inside one harness:

- A fixture worker launch costs about 0.8 to 1 s: one `native-spawn` controller
  process, about ten synthetic `cmux` processes, a runtime and a provider.
- Each fixture controller process (`controller-fixture.py`) started at about
  120 ms (Xcode Python) or 190 ms (Homebrew Python 3.14), against 17 to 23 ms for
  an empty interpreter. It recompiled the controller from source, then ran the
  whole test suite module, which compiled and executed a second controller copy
  and imported `unittest.mock`. It needs only three fixture-edge functions.
- Real-time sleeps are small and deliberate: synthetic provider turns
  (0.08 s; 0.35 to 0.8 s for timing-specific prompts), 10 to 50 ms poll intervals
  under unchanged deadlines. None dominates.
- Each test builds a fresh harness (register plus a synthetic coordinator
  provider, about 0.7 s). Tests mutate its state, so it is not shared.

## Orchestrator changes

1. **Fixture controller start.** `controller-fixture.py` loads the controller
   and `scripts/test-fixtures/orchestrator-controller-edges.py` as modules
   through a run-scoped `sys.pycache_prefix`, instead of `runpy` on the
   controller and the whole suite. The same fixture edges apply; the shipped
   controller is unchanged. Start-up fell to 45 ms with Xcode Python (from 127 to
   130 ms) and to 58 ms with Homebrew Python (from 182 to 195 ms), median of 25.
2. **Resource-accounting capacity cases.** Four tests prove what counts
   against the live-resource limit: a retained terminal across archive, a failed
   attachment's surface, completed workers until their exact surface is
   retired, and unobserved direct sessions. They now set a workspace limit of 4
   through the public `capacity --limit` command and fill it, instead of filling
   the default 32. The admission check is the same for any limit, and
   configured limits are already covered end to end by `WorkspaceCapacityCLITests`.
   `test_pending_launches_hold_all_live_resource_slots` still fills the default
   32-slot reference budget with concurrent pending launches.
