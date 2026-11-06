# Native-child launch policy

[↑ Messaging, launch settings, and capacity](../messaging-launch-settings.md) | [← Native peer messaging](native-peer-messaging.md) | [Local agent launch settings and per-launch preferences →](local-agent-launch-settings.md)

Prospective native children of an interactive managed parent: omitted
`allowTools` and `yolo` inherit parent's explicit **recorded launch policy**.
Born-managed parents also derive allow-all from their exact provider's
launch flags, with bound PID/start-time checks. `--yolo`, `--allow-all`, or all of
`--allow-all-tools`, `--allow-all-paths`, and `--allow-all-urls` qualify (`=true`
supported). Tools plus paths alone stay default rather than widen URL access.
Only mode and source are retained, never argv. Missing evidence defaults,
and an unrecorded manual deny prevents inherited allow-all. Only the controller's
audited benign-option allowlists qualify alongside the allow-all flags.
Unreplayed plugins, configuration/workspace loaders, tool selectors, and other
session selectors default rather than drop unknown restrictions. Owner-approved
exception: `--resume` / `-r` and `--session-id` are benign for launch allow-all
detection, including CMUX-restored sessions; persisted session state is not
inspected. Other refusals still apply. See ADR 0006 for the option boundary.
Spawn reports `permissionMode` and `permissionSource`; descendants retain the
recorded mode. Runtime `/allow-all` toggles are invisible: off-to-on does not
enable inheritance, and on-to-off cannot invalidate recorded launch flags.
Deny-only request keeps recorded mode/allows and adds denies. Explicit
`allowTools` list (including `[]`) or `yolo: false` selects requested default mode
without `--allow-all`. Omitted allows still inherit. Parent denies survive.
Default-mode parents keep literal allow-subset checks. Recorded YOLO parents
permit bounded finite child allow rules without redundant parent allows. They
keep all denies and reject wildcard/broad rules. A coordinator
may request `yolo: true` **only with explicit human approval**, without a narrowing
allow-list. Combining both intents refuses. Workers' explicit YOLO requests still
refuse before credentials/reservation, separately from inheriting parent YOLO.
Missing recorded provenance or policy drift before reservation refuses.

This is **recorded/requested policy, not verified current provider permissions**.
Human `/permissions` changes can make launch records stale. Copilot's
`defaultPermissionMode: "allow-all"` or `COPILOT_ALLOW_ALL` may elevate
a new session despite omitted `--allow-all`. Requested default mode is not
proof of actual manual startup. Inspected SDK exposes current mode/path
getters. It has no verified complete current tool/deny/URL policy snapshot and no atomic
same-or-narrower external-child admission. Full live inheritance/restricted-startup
acceptance stays unverified. No permission callback, persistent setting change,
or launch-then-policy mutation is used.

Each native child has one private Unix socket and a launcher-created binding
under `~/.copilot/extensions/maestro/r/`. Account credentials never enter these
files or messaging tools. Addresses contain workspace/session UUIDs and generation,
not secrets. Limits: payloads 4 KiB UTF-8, frames 8 KiB, registered
participants 128, connections/pending native sends eight per receiver.
Per-workspace live managed session cap is `MAX_LIVE_WORKERS` in
[`scripts/cmux-maestro-orchestrator.py`](../../../scripts/cmux-maestro-orchestrator.py).
It includes managed coordinators and retained resources. Routes use exclusive
creation. Routes retire after exact provider exit (or closed-run archive). Clearing/resuming
a conversation cannot rebind them. Restart/clear/replaced-session,
offline, unsupported, invalid, or stale routes fail closed. Request fresh managed
sessions only with user authorization. Same-user processes are trusted: private
capabilities do not defend against a malicious process running as your user.

See [native delivery findings](../../delivery-proof.md) for observed agent
exchange, human-confirmed draft preservation, separate harness-origin background
check, and outstanding installed-product live acceptance. Mocked contract tests
are not native UI proof.
