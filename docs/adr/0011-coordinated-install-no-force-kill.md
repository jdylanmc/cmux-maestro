# Coordinated install, supervised lock, no force-kill

Install and update publish the app and its owned Copilot integration in one journaled transaction. A kernel-held lock and durable marker stay until every protected worker and provider group exits, even after caller timeout or `SIGKILL`. Update waits up to 120 seconds for exact-identity preview processes to quit normally and aborts if they do not. It never force-kills, quits CMUX, restarts sessions, or injects input.

Why: delayed registration or provider writes from a leftover worker corrupt the next operation. Name-based killing hits unrelated apps.

Rejected: stale-lock deletion, waiting only on direct children or pipe EOF, a separate setup window, force-kill.

Consequence: a hung worker can block all new operations until it exits. Recovery refuses ambiguous state rather than guessing.
