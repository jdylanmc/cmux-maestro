# Controller, hook shell and sidebar reads

[↑ Trust boundary and observation](../trust-boundary-and-observation.md) | [← In-place restart handoff](in-place-restart-handoff.md) | [Temporary status observation loss →](temporary-status-observation-loss.md)

- Terminal control runs in installed standard-library Python controller at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/`.
  Private prompts, results, control tokens, process identities stay under
  `control/`. Sidebar sandbox grant reaches only bounded sanitized
  `observer/` directory. Cannot read sibling control, binary, task or result data.
  Controller uses exact CMUX workspace, pane, surface UUIDs. Never
  infers ownership from labels, paths, focus, chronology, or terminal text.
  `observer/processes.json` adds owned process names, PIDs and TCP listeners
  ([background processes and ports](../processes-and-ports.md)). Never argv or environment.
- Outer hook shell redirects both output streams. Returns zero even
  when helper is missing, fails, or crashes. Hooks cannot supply prompt
  content, tool decisions, or control commands.
- Sandboxed sidebar first does bounded scan of Maestro-owned,
  sanitized routing records in `bindings/<sessionUUID>.json`. Finds records
  matching host's granted surfaces. Reject unrequested records before
  process or session-file reads. Never return their identifiers, counts, or
  content. Routing-index discovery is distinct from reading transcripts.
- Only after surface filtering and stable live-identity verification does
  sidebar read that session's durable events beneath **the real user's**
  `~/.copilot/session-state/`. Displays sanitized, allowlisted metadata,
  never raw transcripts. Does not launch helper. Installs nothing.
  For the same verified session it may read the `name:` field of
  `workspace.yaml` (16 KiB cap, no symlinks, single-line scalar, 200
  characters, control characters removed; ADR 0022). No other field.
  An automatic name can reproduce the session's first prompt; it is
  shown because the CMUX terminal title already shows the same text.
  Tree navigation uses CMUX extension API and current host snapshot.
  CMUX does not push a snapshot on focus changes. A mounted, connected sidebar
  in an active CMUX therefore also pulls its own window's snapshot every 500 ms
  ([host focus refresh](../sidebar/refresh-cost.md#host-focus-refresh)).
  The pull only reads.
  Never fabricate unavailable evidence as live session.

Source contract: Copilot CLI's current durable session/event format.
Only **standard Copilot home** supported. Custom `COPILOT_HOME` and
symlinked state directories not supported. Missing lifecycle events can
leave completion/status unknown. Agent IDs are not automatically native
child-session IDs. No title/transcript heuristics repair missing identity.
