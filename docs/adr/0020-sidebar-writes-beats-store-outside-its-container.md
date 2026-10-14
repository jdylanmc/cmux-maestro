# The sidebar's only write grant outside its container is the Beats store

ADR 0001 limits the sidebar to exact granted prefixes. Its own sandbox container (preferences, history, attention, layout, pets) stays writable as before. Outside the container, every temporary-exception grant is read-only except one: `/Library/Application Support/CMUXMaestroPreview/Beats/` under the real home, the shared Beat definition store (`beats.json`, its `.lock`, and `.pending-*` files during an atomic write). The sidebar still starts no process and opens no socket.

Why: a human creates and edits Beats in the sidebar. A write helper would add a process and a round trip to every edit for the same same-user trust.

Risk accepted: a Beat prompt becomes agent input in its target session, run by that session's Copilot with that session's permissions (ADR 0007). So this grant is an indirect control path: a misled sidebar could queue a prompt for any session it can name. Limits: Beats are authored by a human in the sidebar UI or by an agent for its own proven session; prompts are bounded text (4 KiB); only sessions running the Maestro native-session adapter run them.

A Beat prompt is a human-authored definition (CONTEXT.md **Beat**), not an observed session prompt. The rule against storing or showing raw prompts covers observed session content, not Beat definitions.

Rejected: a write helper for each edit; read-only Beats in the sidebar; signing or attributing store edits.

Consequence: no other grant outside the container becomes writable without its own decision. Any same-user process may edit the store; agent commands prove their own session, and readers check only the store's shape, owner and privacy. The Copilot native-session adapter (`~/.copilot/extensions/maestro/extension.mjs`) keeps its bookkeeping under the real home's `~/Library/Application Support/CMUXMaestroPreview/`, outside `Beats/` and outside every sidebar read grant.
