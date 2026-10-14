# The sidebar writes only its Beats store

ADR 0001 keeps the sidebar read-only. Beats are the one exception: the sidebar may read and write exactly `~/Library/Application Support/CMUXMaestroPreview/Beats/`, the shared definition store (`beats.json` and its `.lock`). It writes Beat definitions, not commands: Copilot's own scheduler, reached by the session's extension, runs them (ADR 0007). The sidebar still starts no process, opens no socket and reaches no other path for writing.

Why: a human edits Beats in the sidebar, and a small private store is cheaper and safer than a helper round trip for each edit. The grant is one directory with an exact path, not broad disk access.

Trust: any process running as the same user may edit the store. Agent commands prove the caller's own session, but the store itself trusts the user account; readers verify only its shape, owner and privacy (owner-only file and directory).

Rejected: a write helper for each edit; read-only Beats in the sidebar; signing or attributing store edits.

Consequence: the read-write grant stays limited to `Beats/`. Another writable path needs its own decision. Extension bookkeeping lives outside `Beats/`, where the sidebar cannot see it.
