# Agent notifications

`maestro_notify({message, priority?})` and
`cmux-maestro-orchestrator notify --message TEXT [--priority normal|urgent]`
post through the installed Maestro app and macOS Notification Center. No
installation, app setting change or session reload happens as a fallback.

CMUX workspace/surface UUIDs are case-normalized. A shell need not export a
session UUID: the sole eligible binding on that exact surface must still prove
the caller's provider ancestry and session custody. Present session hints must
be valid, agree with each other, and match; missing hints never weaken those checks.

The app's one-shot stdin mode needs no preexisting running app and uses accessory
activation policy, without a Dock entry. Explicit app launches keep their setup,
settings and Dock behavior. Click delivery
uses the containing app's notification delegate, including on normal launch.
**Unverified acceptance gates:** real banners, permission prompt and clicks
with Maestro running or cold. The owner performs these after reviewed install.

The title is the exact session's Copilot name, or its managed label when no name
is available (100 characters maximum). The subtitle is its observed state;
unknown or incomplete observation omits that state instead of showing a question
mark. Urgent remains visible even without an observed state. No state is inferred from
the notification message. The attachment is the selected pet's first idle
frame: human override, agent choice, bundled Maestro robot fallback. Invalid
or unreadable custom pets use the bundled robot. macOS decides attachment
placement; this does not reproduce the sidebar header's exact layout.

The body is shortened to 140 characters including an ellipsis. Control and
format characters are stripped. Input is bounded before decoding/processing.
The native/controller boundary conservatively counts Unicode code points;
Swift presentation counts grapheme clusters. Secrets must not be supplied:
Maestro retains no message text, but macOS stores delivered notification content.

Normal is `.active` and silent. Urgent is `.active`, prefixes the subtitle with
Urgent and requests default sound. User notification settings and Focus remain
authoritative; no time-sensitive or critical-alert entitlement is requested.
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
Application Support directory; validation identities do not write it.

The shared private controller ledger permits a burst of three per session,
then refills one token per 60 seconds, capped at three. Failed/uncertain
submissions consume their admitted token. Clock rollback does not refill.
Empty buckets survive process restarts and generation changes for the session.
Fully refilled buckets may expire after an hour. Limits: 1,024 session buckets,
1,024 outstanding click capabilities, one MiB total; exhaustion refuses rather
than evicting live records. Click capabilities expire after 24 hours and are
consumed on the first click attempt. Old or repeated clicks show Unavailable.

Clicks consume and revalidate node, session, generation, workspace, surface,
current provider and sole session custody without using the CMUX socket.
The app writes one exact-target request into the connected sidebar's private
`NotificationClicks` directory. The five-second request is tied to that
connection's nonce and consumed once; the sidebar revalidates sanitized generation
and binding evidence immediately before each existing typed host navigation action.
No connected sidebar, ambiguous window routing, a busy slot, stale identity or
host refusal returns Unavailable, never a deferred click or automatic retry.
The app waits at most 15 seconds for bounded navigation feedback using file events.
The directory is mode 0700 and its files 0600. Each window has one locked lease
and one locked request/result slot; discovery is bounded to 256 entries.
The sidebar retains at most 64 unexpired request identities per connection to
refuse replay. A new connection discards prior requests. No sandbox grant changes.
A minimal passive follow-up uses the original agent name and Unavailable;
it has no action token or sound.

Bundled pet resources accept root or current-user ownership with no group/world
write permission. Custom pets and preference files remain current-user-only.
Unsafe, malformed or unreadable custom pets fall back to the bundled robot.

CMUX's optional **Forward notifications to my iPhone** applies to CMUX-owned
notifications, not these direct Maestro OS notifications. This implementation
adds no phone service, forwarding, credentials or network delivery.
