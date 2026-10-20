# Trust boundary and observation

What the sidebar reads, how sessions bind, what happens when observation is lost. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Data and trust boundary

- Small native executable lives at
  `CMUX Maestro Preview.app/Contents/Helpers/CMUXMaestroCopilotHook`.
- Only `sessionStart`, `userPromptSubmitted`, `postToolUse` hooks run it.
  No veto/control, pre-tool, or agent-stop hooks registered.
- Helper accepts bounded JSON with canonical `sessionId`/`session_id`, plus own
  inherited `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`. Never accepts transcript
  path. Never infers identity from title, current directory, or text.
- Same-user BSD process metadata identifies matching **ancestor**, not
  blindly hook's shell parent. Source `inuse.PID.lock` and stable process
  generation must agree before helper publishes atomic binding.
  Symlink traversal, stale owner generations, mismatched live owners fail
  closed. Missing early session-start marker can retry on later hook.
  Helper and sidebar share marker/process verifier: never read marker contents,
  impose no content-size limit. Birthtime/ctime and rest of marker stat
  snapshot must stay stable. Unknown or multiple live marker owners are
  ambiguous, not guessed.
- Bindings live under
  `~/Library/Application Support/CMUXMaestroPreview/Copilot/bindings/`.
  Own directories `0700`, files `0600`. Dates use milliseconds since 1970.
  Last diagnostic is bounded generic status. Never hook payload, path,
  credential, transcript, or raw CLI error.
- After binding publish, helper also writes `Copilot/locations/<sessionUUID>.json`
  (`0600`, directory `0700`). Holds only `schemaVersion`, `sessionID`, `branch`,
  `worktree` flag, `recordedAt`. Never path or repository name. Helper reads hook
  `cwd` and, for `postToolUse`, last absolute file path or leading `cd <path>`
  in `toolArgs`. Then walks up (at most 40 levels) to `.git` directory or linked-worktree
  `.git` file and reads `HEAD` (4 KiB cap, no symlinks). Runs no `git` process, spawns
  nothing. Detached HEAD, no repository, or any surprise omits the branch fact. Best
  effort. Never changes hook outcome. Taskboard agent card shows that
  branch (worktree adds `· worktree` suffix and own icon). Otherwise no row.
  Existing read-only `Copilot/` grant already covers it.
- Same record, schema 2, adds the session's current worktree (ADR 0027). Helper reads
  `cwd:` from the exact session's `workspace.yaml` through the proven session
  directory, then Git's plain files there (64 levels, 4 KiB, no symlinks, no `git`
  process). Publishes `verified` (16-hex SHA-256 key of the canonical Git directory,
  repository directory name, branch or 7-digit detached commit, linked flag),
  `nonRepository` (readable walk to `/`, no `.git`) or `unknown`, plus the
  `workspace.yaml` device, inode, size and modification time. Sidebar marks it current
  only while that file is unchanged and the session was read live; otherwise last
  known.
- Schema 3 adds one active worktree touch (ADR 0027 amendment): sanitized identity,
  last-touch milliseconds, current-turn flag and exact session/process/placement binding
  fingerprint. The unsandboxed post-tool hook resolves at most eight explicit path hints
  through the existing resolver, memoizing repeated directories within the invocation.
  Shell hints use `shellToolInfo.possiblePaths` when supplied, otherwise the existing leading
  `cd` parser. Raw arguments never reach disk; the hook does not read event logs.
  Prompt/session-start hooks reset current-turn status; last-known touch precedes the
  selected-directory fallback. Changed bindings cannot revive a prior touch. The whole
  record remains private and capped at 2 KiB. The process observer is unchanged.
- Terminal control runs in installed standard-library Python controller at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/`.
  Private prompts, results, control tokens, process identities stay under
  `control/`. Sidebar sandbox grant reaches only bounded sanitized
  `observer/` directory. Cannot read sibling control, binary, task or result data.
  Controller uses exact CMUX workspace, pane, surface UUIDs. Never
  infers ownership from labels, paths, focus, chronology, or terminal text.
  `observer/processes.json` adds owned process names, PIDs and TCP listeners
  ([background processes and ports](processes-and-ports.md)). Never argv or environment.
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
  Never fabricate unavailable evidence as live session.

Source contract: Copilot CLI's current durable session/event format.
Only **standard Copilot home** supported. Custom `COPILOT_HOME` and
symlinked state directories not supported. Missing lifecycle events can
leave completion/status unknown. Agent IDs are not automatically native
child-session IDs. No title/transcript heuristics repair missing identity.

### Temporary status observation loss

Confirmed first status/visibility slice of #119 keeps existing bounded
reader and two-second polling pause. Ordinary updates should appear in roughly
2-3 seconds. 10 seconds or more is too slow. Practical responsiveness
goal. Not a new session cap. Not a reason to increase read bounds.

When ordinary read fails or reliable observation expires, sidebar keeps
exact subject's last known **visual status for five minutes**. Then quietly
shows **Status unavailable**. Fresh valid observation restores current status.
Idle chat is not observation loss: verified unchanged event-file boundary is
still fresh observation. Replayed or older evidence cannot restart grace.

Display memory is separate from current session evidence. Eight-second
trust limit unchanged. Retained status grants no identity, focus,
acknowledgement, dismissal, permission or lifecycle authority. Access denial,
invalid/ambiguous identity, confirmed removal/replacement, and changes to
window, placement, grants or managed generation invalidate retained display.
Recovery after those boundaries requires new valid observation. Unreadable
cached observation cannot seed display memory for new scope. Unsupported
child lifecycle events keep their warning and unknown child state. They do not
suppress independently validated sibling chats.
Partial data can also contain fresh, valid unknown status. That alone is not
observation failure. It does not remove observation before reconciliation.
Internal tasks keep original real open parent, without actionable stale
outcomes. Actual open background tabs stay reachable through current host
metadata. Never fabricate unknown chats without real open surface.
Browser replacing terminal cannot inherit terminal's agent observation.

Regression workload uses 20 synthetic open background tabs with real bounded
file reads, fake-clock idle/failure transitions, and measured reader/projection
cost. Timings exclude two-second pause, host delivery and rendering.
They are not stock-host end-to-end latency claim. Possible 100-chat day
remains nonblocking goal. This slice does not complete #119. It does not authorize
installation, broader settings architecture, or lifecycle changes.
