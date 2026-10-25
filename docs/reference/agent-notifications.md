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

Communication notifications show the sender's selected sidebar glyph/color at
the leading edge, with the system-owned small app-icon badge. The app badge is
not manually composited; its light/dark behavior follows OS icon style and the
separately supplied application artwork. No pet or right-hand attachment.
Human per-session icon overrides and reset-to-default precede the agent's
authored choice. Glyphs use the existing pinned Nerd Font catalog and exact
appearance record; custom colors share the sidebar's sRGB parser/contrast outline.
Unreadable preferences or unavailable glyphs refuse, rather than changing the
human's selected identity.

The system-visible sender title is the localized **Maestro agent**. No session
filename, inferred role or work-state subtitle is supplied. Public content title
and subtitle remain empty; communication metadata supplies the sender title.
Account and conversation handles still contain the exact verified session UUID.

The body is shortened to 140 characters including an ellipsis. Control and
format characters are stripped. Input is bounded before decoding/processing.
The native/controller boundary conservatively counts Unicode code points;
Swift presentation counts grapheme clusters. Secrets must not be supplied:
Maestro retains no message text, but macOS stores delivered notification content
and Siri receives incoming communication donations containing the authored
message, selected avatar and app-specific sender/conversation identity. No
Contacts lookup/write, phone/email association or outgoing interaction is added.
Siri may use donations for suggestions. A completed donation may persist even
if a later identity check or notification submission fails; no automatic retry
or broad cleanup is performed.

Normal is `.active` and silent. Urgent is `.active` and requests default sound.
User notification settings and Focus remain authoritative; no time-sensitive or
critical-alert entitlement, Focus-status access or notify-anyway behavior is
requested. Communication classification can change system prioritization and
people-based Focus handling; it is not identical to an ordinary notification.
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
The controller republishes the sanitized projection from its locked state so
an unchanged live session does not fail solely because its last mutation was
more than 60 seconds ago. Node timestamps and work state remain unchanged.
The app writes one exact-target request into the connected sidebar's private
`NotificationClicks` directory. The five-second request is tied to that
connection's nonce and consumed once; the sidebar revalidates sanitized generation
and binding evidence immediately before each existing typed host navigation action.
No connected sidebar, ambiguous window routing, a busy slot, stale identity or
host refusal returns Unavailable, never a deferred click or automatic retry.
The app waits at most 15 seconds for bounded navigation feedback using file events.
The directory is mode 0700 and its files 0600. Each window has one locked lease
and one locked request/result slot; discovery is bounded to 256 entries.
Normal teardown reclaims inactive window files. Creation and reclamation share
a permanent `.registry` lock; both window locks must be held and their inode
identities checked before removal. Active locks are never unlinked. Admission
and discovery each inspect at most 256 entries for retired crash leftovers;
the routing bound stays 256, and contention/exhaustion still refuses without retry.
The sidebar retains at most 64 unexpired request identities per connection to
refuse replay. A new connection discards prior requests. No sandbox grant changes.
A minimal passive follow-up uses the original agent name and Unavailable;
it has no action token or sound.

Bundled font/catalog resources accept root or current-user ownership with no
group/world write permission, then verify existing pinned hashes. Preference
files remain current-user-only. No session-name or transcript read is needed.

## Production signing prerequisite

The containing app must carry
`com.apple.developer.usernotifications.communication = true` in its effective
signature and a matching, unexpired production profile authorizing that
capability. Its Info.plist declares `INSendMessageIntent` in `NSUserActivityTypes`.
The app checks the effective entitlement before authorizing or donating; without
it notifications return `notification-unavailable`, never an ordinary fallback.

**Current blocker:** the checked-in publication scripts/verifier require ad-hoc
signing and the previously approved unsandboxed entitlement profile. A production
profile alone is not sufficient: owner-approved signing/publishing validation
must also be updated before installation. No signing-policy, certificate,
profile or Developer Portal mutation is part of this source amendment. Do not
use the isolated synthetic test profile or replace production bundles manually.
The sandboxed sidebar needs no communication entitlement or additional grant.

CMUX's optional **Forward notifications to my iPhone** applies to CMUX-owned
notifications, not these direct Maestro OS notifications. This implementation
adds no phone service, forwarding, credentials or network delivery.
