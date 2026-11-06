# Priority, permission and mute

[↑ Agent notifications](../agent-notifications.md) | [← Sender appearance and body](sender-appearance-and-body.md) | [Rate limit and clicks →](rate-limit-and-clicks.md)

Normal is `.active` and silent. Urgent is `.active` and requests default sound.
User notification settings and Focus remain authoritative; no time-sensitive or
critical-alert entitlement, Focus-status access or notify-anyway behavior is
requested. Communication classification can change system prioritization and
people-based Focus handling. It is not identical to an ordinary notification.
Notification request IDs are unique; `threadIdentifier` is the exact session
UUID. Different sessions therefore have separate OS grouping identities and
notifications are not replaced by reusing a request ID.

The first request asks for alert/sound permission if not determined. Denial
returns `notifications-not-authorized`, with no alternate delivery path.
Requests that fail or become uncertain are never automatically retried.
Submission means only the OS accepted the request, not that a banner appeared,
the human read it, or the session completed its work.

The sidebar **Mute agent notifications** applies to every session and both
interfaces. Corrupt/unreadable settings fail closed. Defaults are unmuted.
The file is `sidebar-notifications.json` in the production sidebar's sandbox
Application Support directory. Validation identities do not write it.
