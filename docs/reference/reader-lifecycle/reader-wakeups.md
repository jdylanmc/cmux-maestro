# File-driven reader wakeups

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Projection reuse and publication](projection-reuse.md) | [Conversion caches and acceptance →](conversion-caches.md)

While visible and connected, the Copilot reader watches only the exact directories
of sessions shown (including retained-status rows) or bound on its current
topology, capped at the reader's 64-session limit. One FSEvents stream covers those
directories, and a non-recursive directory-vnode source covers atomic changes in
the bindings directory. Maestro does not watch the whole session-state or integration roots.
Other sessions and unmonitored integration changes use the two-second fallback.
The managed reader watches only the exact orchestration `observer` directory.
Recursive session events include nested appends and atomic replacements.
Registration securely validates the roots. Callbacks never inspect event paths
or read contents, and events only request the fully fenced reader without
establishing identity or freshness themselves.
Shown/bound-set changes replace the registration and request one catch-up read
to cover the registration gap. Events from a retired subscription are discarded.
Ordinary binding-directory `.write` events only wake the reader. They do not
finish the stream, re-register session roots or log watcher retirement; only
directory `.rename`, `.delete` or `.revoke` ends that lease. Invalidating directory
events and recursive stream-loss/root-change batches finish without first yielding
an ordinary change: termination clears the old registration before requesting its
recovery read. Earlier independent changes may still be buffered. The deterministic
registration-count test holds consumption between a change and termination,
including combined flags, so early wakeups cannot hide behind scheduler ordering.

A newest-one stream and one pending-change flag bound bursts and changes during
an in-flight read. The first notification opens a cancellable 200 ms coalescing
window, not a trailing debounce that continuous activity could postpone forever.
No reads overlap, including during topology replacement: the obsolete worker and
watcher unwind before a new scope starts. Visibility/connection/scope cancellation
stops the stream, fallback wait and coalescing task. Independent deadline
timers keep their ownership.

The two-second fallback is slower than notification delivery and is not
shortened. Missing, unsafe or unsupported roots log a sanitized warning and
retain polling. Root replacement, unmount or event-loss flags end the old stream,
request a fully fenced read, and securely re-register at the next reader wakeup.
Missing session directories are excluded when registering, with a sanitized
notice, while the bindings directory and healthy session watches stay active.
Excluded sessions use fallback reads until a later scope/lease registration,
and an unchanged healthy lease does not keep trying to open missing paths.
Unsafe or denied roots still refuse registration instead of counting as
missing.
Failed registration is retried only on the existing read cadence, with no extra
timer or repeated warning while unavailable. Healthy streams do not reopen
roots on each poll. Sandbox entitlements and source read/size bounds do not change.

At an unchanged event-file EOF, the reader uses two descriptor-relative,
no-symlink metadata checks rather than reopening the log. The complete stamp
(device, inode, birth time, owner, mode, size, mtime and ctime) must match both
the retained tail and a previous successful read-open. That read-open is reusable
only when its pre-open entry stamp matched its post-open descriptor stamp, so
concurrent growth or access changes cannot grant a new cached read boundary.
Any mismatch takes the existing secure open/read path. Binding, process,
session-directory and publication fences still run on every read, as do exact
freshness/history deadlines. Torn lines and incomplete tails do not gain
freshness from unchanged metadata. No file contents, access rights or liveness
are inferred from a directory timestamp.
