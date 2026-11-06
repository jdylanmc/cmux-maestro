# Agent notifications

`maestro_notify({message, priority?})` and
`cmux-maestro-orchestrator notify --message TEXT [--priority normal|urgent]`
post through the installed Maestro app and macOS Notification Center, with no
installation, app setting change or session reload as a fallback.

CMUX workspace/surface UUIDs are case-normalized. A shell need not export a
session UUID, but the only eligible binding on that exact surface must still
prove the caller's provider ancestry and session custody. Session hints that
are present must be valid, agree and match. Missing hints never weaken those
checks.

The app's one-shot stdin mode needs no running app and uses accessory
activation policy, with no Dock entry. Explicit app launches keep their setup,
settings and Dock behavior. Click delivery uses the containing app's
notification delegate, including on normal launch.
**Unverified acceptance gates:** real banners, permission prompt and clicks
with Maestro running or cold, which the owner checks after a reviewed install.

## Sender appearance and body

[Sender appearance and body](agent-notifications/sender-appearance-and-body.md)

## Priority, permission and mute

[Priority, permission and mute](agent-notifications/priority-permission-and-mute.md)

## Rate limit and clicks

[Rate limit and clicks](agent-notifications/rate-limit-and-clicks.md)

## Production signing prerequisite

[Production signing prerequisite](agent-notifications/production-signing-prerequisite.md)
