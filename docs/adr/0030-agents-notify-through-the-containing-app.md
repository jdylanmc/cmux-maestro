# Agents notify through the containing app

Owner decision for #370: agents can explicitly notify the human through macOS
UserNotifications, not through CMUX's notification panel. This supersedes the
initial CMUX-text proposal. The containing app owns notification permission,
image attachment and click response handling; the sandboxed sidebar does not
post notifications, launch helpers or open sockets.

The native tool and controller `notify` command resolve the sender from its
exact managed session, workspace, surface, provider ancestry and session custody.
The containing app's one-shot stdin ingress asks the controller to admit that
same caller, then rechecks the target and mute after the permission prompt.
Callers supply only message and priority, never presentation identity or targets.
No listener, daemon, terminal input, adoption or live-session reload is added.

An authored notification message is an explicit content-transfer exception:
bounded, sanitized text goes in memory to the installed containing app and
macOS Notification Center. It is not observed session content. Maestro logs
neither the message nor system error text. macOS retains notification content.

Owner amendment after isolated native proof (#371): use communication
notifications, not a pet attachment. The exact sender's selected sidebar glyph
and color become its avatar, rendered from the existing hash-pinned bundled
font/catalog. Human session overrides and reset-to-default win over authored
agent appearance. The same named/custom colors are used as the sidebar; no
arbitrary fonts or image paths are accepted. Unreadable/invalid preferences or
unavailable glyphs refuse instead of silently replacing a human choice.

The displayed sender is the short localized "Maestro agent", not a session
filename, invented coordinator role or work state. Exact session identity remains
in the opaque account/conversation handle. The system places the sender avatar
at the leading edge and badges it with the application icon; Maestro does not
draw that badge. System icon style controls adaptive artwork, separately owned
by #372. No state subtitle or right attachment is supplied.

This intentionally expands the content-transfer exception to incoming
`INSendMessageIntent` donations: Siri receives the bounded authored message,
avatar and app-specific session/conversation identity. No contact identifier,
phone/email, outgoing human interaction or contact mutation is fabricated.
Donation informs system suggestions and communication prioritization; it is
not a promise of zero Siri persistence. A successful donation can remain even
if subsequent identity revalidation or submission fails. No retention timer,
bulk donation deletion or retry is added. Permission and exact identity/mute
checks precede donation; identity/mute is checked again before submission.

Global mute stays in the sidebar's own sandbox container, separate from layout,
history and attention. The unsandboxed controller reads it. No grant changes.
Rate buckets and one-use click capabilities stay in the private control store,
without message content. Clicks recheck the exact generation, live provider,
session custody and terminal; unavailable targets never fall back to focus.

Amendment (#371): a notification click launches the app under launchd, so
CMUX's default `cmuxOnly` socket policy rejects it (ADR 0021). The controller
consumes and revalidates the click capability without constructing a socket
client. It republishes the sanitized projection from that locked state, without
changing any node timestamp or work state; direct-launched sessions need not
have recently mutated orchestration state for their click to work.
The app writes only the exact target to a private single-use slot in
the sidebar's own `NotificationClicks` directory. A connected window holds a
file-lock lease with a fresh nonce; absence, ambiguous routing or a busy slot
returns Unavailable, never a queued request.

The sidebar consumes the request before acting, rechecks its five-second
expiry and connection nonce, current sanitized generation projection, exact
binding, live provider and sole session custody, then uses the existing typed
host navigation. Each host mutation rechecks identity, including after a
workspace-selection suspension. Disconnect releases the lease; a new connection
discards old requests. The app observes one bounded result through directory
events, with a 15-second failure deadline. No polling, retry, socket bypass,
helper, new entitlement or write grant. The single result is navigation
feedback, never agent completion or messaging evidence.

One permanent `.registry` lock serializes channel lock-name creation and
retirement. Retirement takes both window locks non-blocking and verifies their
inodes before removing only that inactive window's known files. Active leases
and senders retain their lock inodes. Normal teardown reclaims its window;
admission and discovery each sweep at most 256 directory entries for crash
leftovers before applying the unchanged 256-entry discovery bound. Exhaustion
or contention still refuses; no automatic retry or larger scan.

The one-shot `--maestro-notify` invocation uses accessory activation policy;
normal app launches retain setup/settings and Dock behavior. No work state or
session-name reader is needed to format a notification.

Normal uses active interruption with no sound. Urgent uses active interruption
with default sound; no time-sensitive entitlement or Focus-bypass promise.
Communication treatment participates in the OS's people/Focus decisions; no
Focus-status request or notify-anyway metadata is supplied.
The OS owns banner layout and notification grouping, not Maestro.

Production adoption requires a correctly signed containing app with the
Communication Notifications capability and matching production provisioning
profile. The existing ad-hoc publication policy cannot supply this entitlement;
its replacement needs separate owner-approved signing/install work. This source
change adds the intent declaration but does not alter profiles, certificates,
production signing policy or sidebar entitlements. Missing effective communication
entitlement refuses before authorization/donation. The isolated synthetic profile
must never be reused for the production identity.

Real banners, permission prompts and cold-launch click delivery require
human-installed acceptance. Unsigned builds and mocked notification-center
tests do not prove those behaviors.
