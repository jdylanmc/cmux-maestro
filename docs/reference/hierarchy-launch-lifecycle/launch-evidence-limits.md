# Launch evidence limits and legacy workers

[↑ Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md) | [← Launch receipt evidence](launch-receipt-evidence.md)

`render_health`, quiet periods, terminal output and elapsed time prove none of
the phases in [launch receipt evidence](launch-receipt-evidence.md). Inventory/probe errors remain unknown, not death. Confirmed
missing surface can cancel unchanged **legacy** unclaimed lease. Direct
launches cannot infer Copilot never ran: unresolved leases stay retained,
and missing process anchor blocks reclamation. A failed direct attach releases
its lease only with exact provider exit and confirmed surface absence; status,
native close and native spawn run that same release for the caller's tree, only
after the entry point's full actor, invoking-session, custody and provider-ancestry
checks, which repeat under the lock before anything changes. Attach
confirms pane membership from the atomic `surface.list` snapshot, not per-pane
tab reads. Status captures process and host
probes outside global write lock. Then it applies only identity/lease-matched
evidence under lock. Launch receipts revalidate current ownership and
lease at attachment, without startup probes. Changed identities reset status
probe facts to `null`. Retained facts keep their capture timestamp. Cancelled
legacy leases refuse late execution. Direct native observation refuses
foreign surface/session/generation/token/process identities without adoption.
No duplicate spawn, focus change, terminal input or automatic process cleanup
is attempted. Pending launches retain their credential and capacity slot.
If create reply is lost, unidentified possibly-created terminal retains
its slot and blocks archive/recovery. Missing surface identity is not proof
that no resource exists. Reconcile original launch. Never retry it.
Verify exact surfaces, native tools, and returned evidence separately.
Root callers must retain private custody receipt even when startup returns
`ok: false`. Its control token remains private. Controller keeps bounded
setup/attachment errors in private receipts and lifecycle diagnostics. Provider
exec or extension errors remain visible in terminal. Absent native
observation cannot become controller success or failure claim.
Managed coordinators have own controlled sessions and runs. Existing
conversations are not converted. Live or uncertain legacy supervisor blocks
new coordinator schema. Launcher fails rather than interrupting it.
Existing provider sessions need not end when old supervisors
already exited. Resource reconciliation retires only unchanged records
with absent surfaces and proven process exit. Never retires active launch lease.

Lifecycle `follow-up` command remains refused for interactive workers.
Participating peers use [native fire-and-forget messaging](../messaging-launch-settings/native-peer-messaging.md)
instead. No prompt
is injected into terminal input. Close interactive Copilot normally
before archiving. Archive does not interrupt it. Existing legacy workers are
preserved and visibly labeled **Legacy worker**. Never silently converted.
