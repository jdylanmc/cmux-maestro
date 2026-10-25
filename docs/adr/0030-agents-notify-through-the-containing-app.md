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
The first idle frame of the verified session's pet becomes a PNG attachment;
the bundled robot is the fallback.

Global mute stays in the sidebar's own sandbox container, separate from layout,
history and attention. The unsandboxed controller reads it. No grant changes.
Rate buckets and one-use click capabilities stay in the private control store,
without message content. Clicks recheck the exact generation, live provider,
session custody and terminal; unavailable targets never fall back to focus.

Normal uses active interruption with no sound. Urgent uses active interruption
with default sound; no time-sensitive entitlement or Focus-bypass promise.
The OS owns banner layout and notification grouping, not Maestro.

Real banners, permission prompts and cold-launch click delivery require
human-installed acceptance. Unsigned builds and mocked notification-center
tests do not prove those behaviors.
