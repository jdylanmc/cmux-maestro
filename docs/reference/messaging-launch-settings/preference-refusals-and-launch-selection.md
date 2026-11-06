# Preference refusals and launch selection

Part of [messaging, launch settings, and capacity](../messaging-launch-settings.md). Previous page is [Local agent launch settings and per-launch preferences](local-agent-launch-settings.md). Next page is [Workspace launch capacity](workspace-launch-capacity.md).

Refusals use bounded check names: `model-list-invalid` identifies list/count,
ID/duplicate-ID, context/effort array bounds, pricing-tier shape, account drift or
32-KiB projected-evidence checks. `spawn-input-invalid` identifies invocation,
assignment, field, preference or 64-KiB request checks. Account and route
checks use `account-*` and `route-*`; an unavailable binding operation names its
spawn stage without exposing filesystem errors. `controller-*` distinguishes
path/file checks, timeout, execution/output failure, invalid reply and a
controller refusal. Controller capability validation uses
`launch-capability-invalid`, and a missing configured fallback uses
`launch-preference-unavailable: configured-fallback`. These are diagnostic
categories, not permission to retry or bypass a refused check.
The bounded parser is installed as `models.mjs` alongside `adapter.mjs`;
setup publishes the required parser before its importing adapter, so an
interrupted upgrade never exposes the new adapter without its dependency.
Coordinated rollback restores native modules in reverse publication order,
restoring the previous adapter before removing a newly introduced parser.
Hook, observer, receipt, and settings restoration retain their existing order.
Missing or oversized modules make integration readiness fail closed.

Supported selections feed actual `--model`, `--context` and
`--reasoning-effort` arguments. Unsupported safe optional requests **warn**:
an unavailable requested model falls back only to the configured pin when that
pin is available in the session catalog. No available configured fallback
means refusal, never arbitrary model substitution. A valid selected model
survives an unsupported context/effort request: context falls to its default
tier, effort to its advertised default (or no override when unavailable).
Unavailable experimental model lookup warns and preserves the old configured
launch without optional overrides. Unsafe input, missing credentials,
ownership, permission, and capacity failures are not preference fallback.

Bounded private `launchSelection` record and receipt distinguish requested
preferences, configured arguments, evidence source, and warnings. `observed`
stays unknown. `long_context` is a supported tier, not a numeric context-window
claim. Account entitlements and actual provider application stay unverified
until independently observed. On a supporting installed adapter,
`maestro_identity({"includeModel":true})` reads the responding session's
`session.rpc.model.getCurrent()` and returns a bounded `modelObservation`:
`observed` with source, timestamp, and actually reported model/context/effort,
or `unavailable` with a reason. Unreported context/effort is omitted, not replaced
with launch defaults. No catalog, plan-model alternative, or raw error is returned.
Account and exact binding are rechecked after the read. Drift refuses.
Default identity calls keep existing account-only behavior and make
no model query. Parent cannot use this to observe a child. Child must make
its own explicit query. This does not wait for startup, poll, persist observations,
switch models, or prove entitlement, token-window size, or installed execution.
Timestamp is local collection time, not an atomic provider revision.
A reported virtual `auto` model does not identify the backing model of a turn.

CLI adds `spawn --model`, `--context-tier` and `--reasoning-effort`. Direct
callers lack joined-session evidence, so new selections warn and keep
configured defaults. `launch-coordinator --model` keeps its pre-existing
explicit-over-configured precedence and syntax validation. It claims no
session-catalog support. Its new context/effort options warn and stay omitted.
Neither native Settings nor persistent Copilot configuration changes.
