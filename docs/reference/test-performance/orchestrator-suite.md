# Orchestrator suite

[↑ Test performance](../test-performance.md) | [← Sources and separating the costs](sources.md) | [Orchestrator suite evidence →](orchestrator-evidence.md)

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
