# Agent notifications

`maestro_notify({message, priority?})` and
`cmux-maestro-orchestrator notify --message TEXT [--priority normal|urgent]`
post through the installed Maestro app and macOS Notification Center. No
installation, app setting change or session reload happens as a fallback.

CMUX workspace/surface UUIDs are case-normalized. A shell need not export a
session UUID: the only eligible binding on that exact surface must still prove
the caller's provider ancestry and session custody. Present session hints must
be valid, agree with each other, and match. Missing hints never weaken those checks.

The app's one-shot stdin mode needs no preexisting running app and uses accessory
activation policy, without a Dock entry. Explicit app launches keep their setup,
settings and Dock behavior. Click delivery
uses the containing app's notification delegate, including on normal launch.
**Unverified acceptance gates:** real banners, permission prompt and clicks
with Maestro running or cold. The owner performs these after reviewed install.

## Sender appearance and body

See [sender appearance and body](agent-notifications/sender-appearance-and-body.md).

## Priority, permission and mute

See [priority, permission and mute](agent-notifications/priority-permission-and-mute.md).

## Rate limit and clicks

See [rate limit and clicks](agent-notifications/rate-limit-and-clicks.md).

## Production signing prerequisite

See [production signing prerequisite](agent-notifications/production-signing-prerequisite.md).
