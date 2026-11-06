# Data and trust boundary: hooks, bindings and locations

[↑ Trust boundary and observation](../trust-boundary-and-observation.md) | [In-place restart handoff →](in-place-restart-handoff.md)

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
- Copilot `/restart` and `/update` hand a live binding to the bound owner's
  exact direct child. See [in-place restart handoff](in-place-restart-handoff.md).
- Bindings live under
  `~/Library/Application Support/CMUXMaestroPreview/Copilot/bindings/`.
  Own directories `0700`, files `0600`. Dates use milliseconds since 1970.
  Last diagnostic is bounded generic status. Never hook payload, path,
  credential, transcript, or raw CLI error.

### Session locations and worktrees

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
  `cd` parser. Raw arguments never reach disk. The hook does not read event logs.
  Prompt/session-start hooks reset current-turn status; last-known touch precedes the
  selected-directory fallback. Changed bindings cannot revive a prior touch. The whole
  record remains private and capped at 2 KiB. The process observer is unchanged.
