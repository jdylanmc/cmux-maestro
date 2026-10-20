# Current worktree comes from the session's own selected directory

The observer hook records which Git worktree each exact session is working in. It reads the session's selected directory from the `cwd:` field of Copilot's `~/.copilot/session-state/<session-id>/workspace.yaml`, through the session directory it has just proved it owns (the binding proof of [ADR 0002](0002-exact-identity-evidence-never-heuristics.md)). It then reads only Git's plain files under that directory, as the branch fact already does ([ADR 0014](0014-git-probes-run-outside-the-sandbox.md)): no `git` process, no environment, no symlinked `.git`, `HEAD` or `commondir`, at most 64 levels and 4 KiB per file. It runs at every hook the observer already receives (session start, prompt submitted, after a tool), and writes nothing when the result is unchanged.

The result is one of three:

- **Verified**: an opaque key, the first 16 hex digits of a SHA-256 of the worktree's own canonical Git directory; the repository's directory name for display; the branch, or `Detached HEAD` and a 7-digit commit; whether it is a linked worktree. Two worktrees of one repository at one commit have different keys. A branch change keeps the key. The same name or branch in another repository is a different key.
- **Not a repository**: the selected directory exists, and every directory from it to `/` was read and has no `.git`.
- **Unknown**: everything else. No `cwd:`, a missing or unreadable directory, denied traversal, a malformed or symlinked Git entry, a bare repository, a Git administrative directory, or an unsupported `HEAD`. Unknown is never "not a repository".

The record also holds `workspace.yaml`'s device, inode, size and modification time when it was read. The sandboxed sidebar compares them with the file it already stats for the session name. The evidence is current only while they match and the session was read live this cycle. Otherwise it is last known. Copilot rewrites `workspace.yaml` when `/cwd` changes the directory, so the change is visible at once, and the next hook re-observes it.

The record keeps the earlier branch fact from tool paths and payload `cwd`, which the Taskboard shows, and adds the current worktree as schema 2 in the same file, `Copilot/locations/<session>.json` (`0600`). The sidebar reads it through its existing read-only grant. It receives no path. The repository directory name is a display label, never identity.

Why: on 2026-10-02 two sessions changed directory with Copilot's `/cwd`. Their process and shell directories stayed the same, but `workspace.yaml` `cwd:` followed, and Git's files there told two worktrees of one repository at the same commit apart (#59). The CMUX surface directory ([ADR 0018](0018-surface-directory-from-cmux-report-only.md)), the controller's assigned directory ([ADR 0014](0014-git-probes-run-outside-the-sandbox.md)), a tool path, a title, a branch label, a pane or a parent session say nothing reliable about the current worktree. One producer in the hook covers managed and unmanaged sessions alike.

Rejected: Git in the sidebar. The controller probing Git, since it runs only when a control command does. The process or shell working directory. Deriving a child session's worktree from its parent. Using the repository or branch name as the grouping key. A second Git collector.

Consequence: a session shows no current worktree until its first hook after this release. A branch switch made outside the session (another terminal) is seen only at that session's next hook; the sandboxed sidebar cannot read the worktree's `HEAD`, so until then the branch label can lag. The grouping key, the worktree's own Git directory, does not change with the branch, so membership stays right. Copilot's `workspace.yaml` is not a documented interface. `cwd:` is read only when the whole file is a flat mapping the hook models (plain keys once each, one-line plain or quoted values, indented block scalars); a flow collection, quoted key, multi-line value, anchor, alias, tag, document marker or duplicate key makes the evidence unknown, never wrong. All 1,375 local session files checked on 2026-10-19 fit that shape. A `workspace.yaml` rewrite that does not change the directory still marks the evidence last known until the next hook. This amends ADR 0014: the sidebar now receives a repository directory name and an opaque worktree key, still no path. It amends ADR 0022 only in that the hook, outside the sandbox, reads one more `workspace.yaml` field; the sidebar still reads only `name:`.

## Amendment: active repository from tool touches (#279, 2026-10-20)

The owner launches sessions outside Git and works across repositories without changing
Copilot's selected directory. Worktrees therefore groups by the **last verified tool touch
in the current user turn**, then the last verified touch marked last known, then the
selected-directory observation above, then Unknown/No repository. Only one group per
session; repository labels, titles, branches, panes and parents remain non-evidence.

The already registered post-tool hook resolves explicit file/directory path arguments,
or shell `possiblePaths` when supplied, using the same `CopilotWorktreeResolver`. When
the hook provides only shell command text, the existing bounded leading `cd` parser supplies
the path; it does not execute or persist the command. The hook never opens an event log to
recover missing arguments. A failed, absent or non-repository touch cannot erase a verified
touch. Within a multi-path call, the last verified path in provider order wins; this order
is not evidence of chronological execution inside the tool.

`userPromptSubmitted` and `sessionStart` close the previous window. Those two registered
hooks have no tool name; only `postToolUse` has one. Missing/malformed tool metadata thus
fails conservatively to last known. A successful touch starts the current window again.
New process bindings cannot make an old touch current.

Schema 3 keeps only one sanitized worktree identity, last-touch milliseconds, current-window
flag and exact binding fingerprint alongside schema 2's selected-directory fallback.
There is no touched-file list or history. Storage stays at 2 KiB per session. At most eight
path hints are admitted per hook; oversized lists contribute no touch. Resolution results
are memoized by containing directory for that invocation only, so repeated paths share a
Git walk. No paths, filenames, commands, argv, or persistent path cache are written. The
existing 64-level/4-KiB resolver bounds and exact session ownership proof stay in force.
Relative paths and paths containing `..` contribute no new touch: lexically removing a
parent component across a symlink can select the wrong repository. Ambiguous later `cd`
targets invalidate the shell hint instead of reusing an earlier directory in that command.
Quoted targets followed by concatenated word fragments, extra arguments or unsupported
shell separators likewise contribute no hint; a quoted prefix is not a complete shell path.

The optional live-process cwd supplement is deferred: ADR 0029's Python observer currently
collects a process table, start identities and listeners, not cwd. Resolving those paths
would require another probe and a new cross-language helper route or a second Git collector.
Neither is a cheap addition to the existing pass. Tool touches remain the only new producer;
no process observer, adapter, sandbox grant, or installed configuration changes here.
