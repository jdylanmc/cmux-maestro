# Display clock, expiry and CPU acceptance

Part of [sidebar presentation](../sidebar-presentation.md). Previous page is [Refresh and render cost](refresh-cost.md). Next page is [Agent icons](agent-icons.md).

Copilot's raw tree and evidence stream still publish exact observation timestamps.
The outline observes a separate presentation key: semantic content, freshness
classes and displayed minutes. Each immutable render snapshot carries its display
clock. Timestamp-only refreshes do not redraw it within the same displayed minute.
Existing Copilot, history, managed-node, Git and process deadline notifications
advance the display independently. Workspace render equality preserves local
content and global duplicate-identity barriers. Actions revalidate current raw
evidence using the actual clock, not a captured display clock. Hidden agent
previews do not build card data. Opening a preview reads current evidence.

History expiry keeps one exact next-deadline wake-up. Each pass coalesces all
already-due transitions and reuses unaffected session projections after global
identity, topology and trust checks. Settings, evidence changes and per-session
clock boundaries invalidate that reuse. An early timer wake re-arms without
declaring an expiry. Retention is never rounded or delayed to reduce CPU.
The local `history-expiry` log category emits aggregate wake, retention-wake,
repeated-deadline and session-projection counts at most once per 60-second window
with expiry activity. It contains no identity, content, path or evidence timestamp,
and no diagnostic polling timer runs. Sampled stacks alone do not establish how
many distinct deadlines fired.

For installed CPU acceptance, select the exact extension PID and record the installed
commit separately, then run this read-only local probe:

```sh
python3 scripts/measure-sidebar-cpu.py --pid <exact-pid> --output <new-private-directory>
```

It records 13 `ps` observations over 60 seconds and a five-second stack sample,
refusing process-start changes. The interval CPU percentage uses CPU TIME delta,
not the smoothed `ps` percentage. `sample.txt` is private diagnostic evidence and
may contain local paths: do not upload it. Compare the same sidebar content and
motion settings before/after an explicitly authorized install. A build, synthetic
mounted test or sample capture alone does not prove the 0-2% idle CPU target.
