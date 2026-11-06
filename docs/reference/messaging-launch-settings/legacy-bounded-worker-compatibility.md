# Legacy bounded-worker compatibility

[↑ Messaging, launch settings, and capacity](../messaging-launch-settings.md) | [← Host safety limits](host-safety-limits.md)

Existing bounded workers keep `follow-up` and `report`. Follow-up queues privately only after a directly owned
worker has a successful exact-session boundary for its current generation.
It then uses that worker's preassigned exact `--resume` session ID. Explicitly reported
outcomes are preferred. A report-missing or permission-denied generation may be
re-prompted without claiming its earlier task succeeded.
Supervisor multiplexes bounded JSON output and promptly forwards provider
diagnostics. It continues current-generation heartbeats during silent turns.
It never answers permission prompts. Noninteractive Copilot can deny a tool in
JSON without offering an interactive prompt, so stderr inheritance is not a
permission mechanism. Terminal existence and a zero CLI exit are
not success. Completed, blocked, and failed states require both a successful
exact-session process boundary and one strict generation-matched whole-final-
message report. Report is versioned, identity-bound, and permission-free.
Refused: ordinary prose, fenced or extra JSON, tool-bearing final messages, and dual
helper/final reports. It stays a worker self-reported outcome,
not independent artifact validation or reviewer acceptance. Missing reports,
permission denials, nonzero
or malformed turns, startup failure, process
disappearance, and terminal disappearance stay distinct. An explicit launch
lease prevents archive from crossing CMUX surface creation/attachment. Any
exact surface created before a later launch failure stays accounted. Eight
still-live managed worker resources are allowed per workspace.
Reported completion does not free a slot. Archive retains bounded history and
never kills processes or deletes tabs, so still-present archived worker tabs
keep consuming the resource bound. Tool permissions are not auto-approved.
Interactive archive checks exact process exit under the lock both before
admission and before deletion. Failed process probes stay uncertain, not
proof of exit. Interactive-only runs need no cooperative stop marker, so a
refused archive leaves their records, messaging routes, and archive flags intact.
Cancelling an unclaimed launch lease records explicit pre-runtime failure
evidence. Stale recovery can retire that never-started worker after its exact
surface is closed (or when creation produced no surface), even without process
anchors. Missing anchors alone, idle time, and startup timeouts are not exit
proof. No-start evidence requires lease cancellation before runtime
claimed ownership. Legacy supervisors keep their cooperative archive stop.
Read-only controller snapshots use shared locks. State mutations stay
exclusive. Idle supervisors therefore do not serialize their status reads
behind the mutation lock as a workspace approaches its worker limit.
Spawn accepts bounded caller-explicit `--allow-tool` and `--deny-tool` rules.
Registered/legacy defaults add no grants. Denies win. Descendants cannot
exceed their parent's explicit allows or remove inherited denies. Prospective
native interactive children inherit recorded parent policy as qualified in
[native-child launch policy](native-child-launch-policy.md).
Legacy bounded behavior is unchanged. These Copilot flags are policy controls,
not an operating-system sandbox. No shell or wildcard grant is synthesized from
tool visibility or prompt text. Recorded parent YOLO and explicitly approved
coordinator YOLO requests append `--allow-all` while retaining denies.
