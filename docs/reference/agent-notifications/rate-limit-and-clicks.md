# Rate limit and clicks

[↑ Agent notifications](../agent-notifications.md) | [← Priority, permission and mute](priority-permission-and-mute.md) | [Production signing prerequisite →](production-signing-prerequisite.md)

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
and one locked request/result slot. Discovery is bounded to 256 entries.
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
