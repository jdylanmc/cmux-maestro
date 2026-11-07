# Data and trust boundary: hooks, bindings and locations

[↑ Trust boundary and observation](../trust-boundary-and-observation.md) | [In-place restart handoff →](in-place-restart-handoff.md)

- Small native executable lives at
  `CMUX Maestro Preview.app/Contents/Helpers/CMUXMaestroCopilotHook`.
- Only the `sessionStart`, `userPromptSubmitted` and `postToolUse` hooks run
  it. No veto/control, pre-tool or agent-stop hooks are registered.
- Helper accepts bounded JSON with canonical `sessionId`/`session_id`, plus own
  inherited `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`. It never accepts a
  transcript path or infers identity from title, current directory or text.
- Those values are only a claim. Before a binding is created or moved to
  another placement, a live CMUX must report the claimed surface with the
  owner's controlling TTY (`cmux top --all`, bounded to 2 s and 4 MiB). An app
  or multiplexer started from a CMUX tab passes that tab's values to its own
  terminals; their sessions stay unbound (`unplaced`). Any doubt (no answer,
  unknown TTY, untrusted CLI) also leaves the session unbound. A refresh of this
  owner's own binding in the same placement is not re-asked.
- Same-user BSD process metadata identifies matching **ancestor**, not
  blindly hook's shell parent. Source `inuse.PID.lock` and stable process
  generation must agree before helper publishes atomic binding.
  Symlink traversal, stale owner generations, mismatched live owners fail
  closed. A missing early session-start marker can retry on a later hook. Helper
  and sidebar share the marker/process verifier, which never reads marker
  contents and imposes no content-size limit. Birthtime/ctime and rest of marker stat
  snapshot must stay stable. Unknown or multiple live marker owners are
  ambiguous, not guessed.
- Copilot `/restart` and `/update` hand a live binding to the bound owner's
  exact direct child. See [in-place restart handoff](in-place-restart-handoff.md).
- Bindings live under
  `~/Library/Application Support/CMUXMaestroPreview/Copilot/bindings/`.
  Owned directories are `0700` and files `0600`. Dates use milliseconds since
  1970. The last diagnostic is a bounded generic status, never a hook payload,
  path, credential, transcript or raw CLI error.

### Session locations and worktrees

- After binding publish, helper also writes `Copilot/locations/<sessionUUID>.json`
  (`0600`, directory `0700`). Holds only `schemaVersion`, `sessionID`, `branch`,
  `worktree` flag, `recordedAt`, never a path or repository name. Helper reads hook
  `cwd` and, for `postToolUse`, last absolute file path or leading `cd <path>`
  in `toolArgs`, then walks up (at most 40 levels) to a `.git` directory or
  linked-worktree `.git` file and reads `HEAD` (4 KiB cap, no symlinks). It runs
  no `git` process and spawns nothing. Detached HEAD, no repository or any
  surprise omits the branch fact. This is best effort and never changes the hook
  outcome. The Taskboard agent card shows that branch (a worktree adds a
  `· worktree` suffix and its own icon); otherwise there is no row. The existing
  read-only `Copilot/` grant covers it.
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
  `cd` parser. Raw arguments never reach disk. The hook does not read event logs.
  Prompt/session-start hooks reset current-turn status; last-known touch precedes the
  selected-directory fallback. Changed bindings cannot revive a prior touch. The whole
  record remains private and capped at 2 KiB. The process observer is unchanged.
