# Workspace launch capacity

Part of [messaging, launch settings, and capacity](../messaging-launch-settings.md). Previous page is [Preference refusals and launch selection](preference-refusals-and-launch-selection.md). Next page is [Host safety limits](host-safety-limits.md).

Controller `capacity --workspace <workspace-uuid>` command returns a
read-only, **advisory** preflight. It needs no provider credentials or host RPCs.
Authenticated `status` also includes the same workspace-wide `capacity` summary:
managed roots, workers, retained resources, pending launches, used
slots, configured limit, and workspace stored-node slots. Pending leases are
already counted through their managed nodes, not added twice. Unknown or stale
process/terminal ownership is not free capacity.

Repeated status reads preserve `resource-retired` while the exact surface is
absent and the recorded processes are proven ended. A launch proven never to have
created a surface remains retired too. Current absence and process observations
still appear in status; retirement does not erase the outcome, identity or
generation. A restored surface, live process or uncertain observation removes the
retirement exemption without adopting a session or inferring work state. Status
and admission use the same absence test and reject observations from a changed
session, generation, ownership or launch lease. Only normal guarded admission
reconciliation establishes new resource retirement; status does not retire other
ended nodes only because their phase says `terminal-disappeared` or
`process-disappeared`. Those nodes may still own a surface or process, so they
remain charged. An accepted close alone never releases capacity.

To persist a limit, a human-directed workspace coordinator uses:

```sh
python3 scripts/cmux-maestro-orchestrator.py capacity \
  --workspace <workspace-uuid> --limit 64 \
  --actor-id <coordinator-id> --token <private-control-token>
```

Keep control token private, as with other authenticated controller commands.
Worker actors and coordinators from other workspaces cannot change the limit.
Limits are integers from **1 through 128**, default **32** when omitted.
They live in existing private `Orchestration/control/state.json`, separately
from account/model settings. Native Settings does not edit them. Lowering a limit
below current usage preserves every session and retained resource. It refuses
new admissions until usage permits them. No automatic cleanup or reuse occurs.

A successful preflight reserves nothing. Root and child launch reservations
recheck latest limit and exact resource usage inside their exclusive
transaction. Separate **128-node per-workspace** and **8-level** bounds still apply. A
configured limit of 128 does not guarantee 128 available nodes or demonstrate
128-provider load. `storedNodes`, `storedNodeLimit` and `nodeSlotsRemaining`
count only the queried workspace, including resource-retired history and
registered coordinators. Another workspace's history does not consume these
slots. Retained terminal records stay separately bounded to 128 per workspace.
Live-workspace `remaining` alone is not an
admission check. Increasing live capacity, closing a tab, or deleting records
automatically does not repair history exhaustion.
