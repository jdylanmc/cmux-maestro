# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Changed

- Collapsed workspace headers stack compactly without margins reserved for
  expanded content. Dividers, control targets and expanded layout stay unchanged
  in both densities (#319).
- Agent hover process lists omit exited PIDs, including from overflow counts.
  Current and detached processes remain visible; ended sessions and uncertain
  observations retain their status labels (#304).
- Agent TCP listeners share one wrapping **Ports** field, deduplicated per process
  and port, with compact binding scope and overflow. Current, complete observations
  offer explicit HTTP browser links and exact endpoint copies; no probing (#305).
- Hover cards, details, footer and tooltips use terse evidence labels instead of
  explanatory prose. Stale/unavailable observations, incomplete child history,
  directory provenance and Git count exclusions remain visible. Old managed
  nodes stay visibly stale inside fresh snapshots; workspace attention and
  omitted totals keep their uncertainty qualifiers (#298).
- Agent hover processes share one wrapping **Processes** field with named PIDs
  and inline overflow. Copy returns visible current PIDs, one per line; stale,
  incomplete and retained process states remain explicit (#296).
- Required CI uses causal setup/polling checks and fixed replay identities, with
  a guard against new timing-sensitive tests. Venue-dependent native acceptance
  is explicitly opt-in; its exact exclusions and remaining behavioral coverage
  are documented in the CI test policy (#276).
- Installer lease tests await an explicit provider readiness signal across
  compensation, report early installer exits, and release delayed fixtures on
  assertion failure instead of depending on a short startup budget (#345).
- Native guide acceptance tolerates a proven base advance or retarget while
  retaining the exact candidate. Producer failures report their original cause
  instead of launching dependent validators without evidence (#276).

### Added

- Saved footer pets, including Maestro, show a pencil badge on hover to open
  the pet picker. Unsaved agent-made pets keep their save badge and confirmation.
- Agents can notify the human through macOS with their selected sidebar glyph
  and a short "Maestro agent" sender title, not a session filename or pet.
  Communication notifications use the system app-icon badge and incoming Siri
  donations; production requires an explicit development provisioning profile
  and matching existing signing identity. Owned ad-hoc rollback stays supported.
  Publication checks every architecture's entitlements and refuses unsafe
  profile files without blocking. macOS profiles need no debugging grant;
  published apps do not claim debugging access.
  Own-session tools and CLI share a global mute, rate limits and
  exact-terminal click checks through a connected sidebar; urgent adds sound.
  No work state is inferred; notification-only sending stays out
  of the Dock (#370).
- CMUX Maestro has its own Legato / Glacier app icon, separate from session
  icons and pets. macOS 26+ supports native light/dark appearances through the
  system icon style; older macOS uses a static light fallback (#372).
- Collapsed workspace and worktree headers keep an aggregate activity glyph and
  count. Input and blockers take priority over failures and working agents;
  incomplete evidence stays visible. Activate the cue to expand, without
  focusing or acknowledging a session (#290).
- Icon and tag editors keep their swatches and add **Custom…**, the macOS system
  color picker, for any opaque sRGB hex (#294). Custom tags retain readable
  black/white text; custom icons retain a contrasting outline. Dragging previews
  locally and commits once on panel close or Save/Done; the editor stays open. Named-only
  preferences remain format 1; custom choices use format 2, which older builds
  preserve but cannot display. Agent color APIs remain named-only.
- `/maestro-demo` runs a human-requested live demo with two visible workers (three
  on request), distinct icons, self-assigned tags, original self-drawn pets, and
  one native-message follow-up each. Closing stays optional and human-approved.
  Workers reuse an already-trusted folder read-only, keep artwork in separate
  scratch space, and report to the exact spawning parent, including nested demos.
  The manual CLI Integration install command now includes both global skills;
  guide-content comparison still checks only `/maestro`.
- Worktrees follows the repository an agent most recently touched, even when launched outside
  Git (#279). A new user turn keeps the previous repository as last known until another touch;
  sessions without a touch retain the selected-directory fallback. Pinned details no longer
  show explanatory identity or binding prose.
- The managed agent hover shows the agent's background processes (#78) and the TCP ports they
  listen on (#75): copyable PIDs and bound endpoints, with loopback, all-interface and network
  listeners distinguished. Copilot's own helpers are counted, not listed. Stale, incomplete,
  denied and unproven observations never show a current list. Never a probe.
- The Hierarchy has a **Worktrees | Sub-agents** control (#58, ADR 0028). Workspaces stay on top.
  Worktrees groups each workspace's agents by their exact session's current worktree: a header
  with the repository, `branch · tree` or `Detached HEAD · commit · tree`, and the agent count,
  then `No repository` and `Unknown` groups. Sub-agents is the spawning tree. The choice is
  global and saved. A collapsed group or parent shows an icon card: every agent's icon and
  state in one row that scrolls inside the card; each icon focuses its agent.
- The observer hook records each session's current worktree from its own selected directory,
  `workspace.yaml` `cwd:`, which follows Copilot's `/cwd` (#59, ADR 0027). It reads Git's plain
  files there: an opaque key that tells worktrees of one repository apart, the repository name,
  and the branch or detached commit. It reports `nonRepository` only after reading every
  directory up to `/`, and `unknown` otherwise. The sidebar treats it as current only while
  `workspace.yaml` is unchanged; otherwise it is last known. No path reaches the sidebar.
- Agent hover cards show the hovered session's own pet, independent of the active
  window's footer pet (#50). Children, terminals, browsers and workspaces show none.
  Row **Appearance > Choose pet…** opens the pet picker for that exact session. The
  picker adds **Reset to default**, distinct from **Reset to agent's pet**, and a
  per-session **Hide pet** / **Show pet**, persisted by session UUID.
- Agent tags (#51, ADR 0026). **Edit tags…** in an agent row's actions, pinned details and the
  details popover sets your tags for that exact session; agents tag their own session with
  `cmux-maestro-orchestrator tags add|remove|list|clear --self`. Tags show as compact chips inline
  with expanded agent titles, and with their owners in details, hover cards and the Beats panel.
  The same tag from you and the agent is one chip; removing it from one side keeps the other.
  Colors are automatic per tag, or a human-chosen swatch or custom color for that tag everywhere; agents
  cannot set colors. Text contrast is at least 4.5:1. See
  [agent tags](docs/reference/agent-tags.md).
- A new controller command, `process-observe`, publishes each managed agent's owned background
  processes and their TCP listeners to `observer/processes.json` (#78, #75, ADR 0029). Ownership
  comes from the node's recorded session, generation and provider process; identity is PID plus
  microsecond start time. Names only, never argv or environment. A process that leaves the tree is
  reported once as detached and never attributed again. The installed adapter gains
  `processes.mjs`, which asks for a pass when a session becomes managed, after tool use and agent
  stops, and every 10 s until it ends. See `docs/reference/processes-and-ports.md`.
- Setup installs CMUX's Copilot hooks in a separate owned file,
  `~/.copilot/hooks/cmux-maestro-cmux-hooks.json`, with CMUX 0.65.1's exact commands (#252), so
  CMUX's own restore can bring back sessions you start. CMUX's own installer fails on Copilot's
  commented `config.json`. Setup refuses, by name, a file there that Maestro did not write.
  Uninstall removes the file in the same transaction as the other entry points, only when its
  bytes are a manifest Maestro shipped, and names a file it left in place.
- Born-managed rows in the sidebar show their Copilot session name, from the exact observed
  session, instead of `Copilot session` (#252, ADR 0022 amendment). The controller projects
  `enrollment: "born"`; the sidebar refuses that value on any other node.
- Maestro-launched sessions resume after a CMUX relaunch (#252). Each launch sets
  `CMUX_COPILOT_HOOKS_DISABLED=1` and attaches a CMUX resume binding with identifiers only. On
  relaunch, the new `resume <session>` command checks the exact surface and its terminal, an
  ended session, and the recorded policy and account, then resumes `copilot --resume=<session>`
  as the next generation. Approve the prefix `<controller> resume` once in CMUX Settings >
  Terminal > Resume Commands. A session that ends with `/exit` clears its binding; a quit or
  crash keeps it. The binding runs the
  installed controller path, so Python and app upgrades do not break it.
- A born-managed root resumes as managed after a CMUX relaunch (#252). When CMUX restarts its
  session in the same surface, the controller resumes the same node as its next generation, in
  the same run, with its children. It refuses a session the human ended with `/exit`, a live or
  uncertain session, a different surface, or a different account; for an account mismatch,
  `maestro_readiness` names the recorded login. A quit, hangup, or signal is not an `/exit`. See
  `docs/reference/relaunch-restore.md`.
- Copilot sessions you start in a CMUX terminal are born managed (#252, ADR 0025). After setup,
  each new session enrolls itself as its own root: it can see and message its workspace peers
  and spawn and close its own children. It records your session's account, with no credential,
  and a default policy with no grants. Sessions that were running before setup stay unmanaged.
  At capacity, or if any identity check fails, the session stays unmanaged and
  `maestro_readiness` says why. A new session in a tab whose earlier born run has fully ended
  archives that run first; `archive-ended --workspace <id>` archives every such run by hand.
- Managed nodes have one recorded account `{login, host}` (#252): the launch's pinned login, or
  the account a session reported itself. No credential is stored. ADR 0024 sets one restore owner
  per node and the rules for resuming an ended managed session after a CMUX relaunch; ADR 0004
  now limits the fresh session ID to new workers.
- Reorder workspaces, and the surfaces in one workspace, in Maestro's sidebar. Drag a row's
  title, or use **Move Up** and **Move Down** in its actions menu or as VoiceOver actions.
  The order is Maestro's only and is never sent to CMUX (ADR 0021): it lives in the
  sidebar's own `sidebar-order.json`, keyed by CMUX UUIDs. Pinned items stay among pinned
  ones, surfaces stay in their workspace, and new items appear after their CMUX
  predecessor. Root managed agents reorder among themselves in their workspace's surface
  list; nested agents and session rows move with their parent, and their menus say so.
  An item with unknown pin state keeps its place. **Reset Workspace Order** / **Reset
  Order in Workspace** in the menu, and **Reset sidebar order** in settings, return to
  CMUX's order. VoiceOver announces each move or why it was refused. Drag is being
  piloted inside CMUX. The disabled "Move or reorder…" item is gone.
- A Beat icon at the far right of an agent row, after its actions button and 8 pt in from the
  row's trailing edge, whose exact Copilot
  session has an enabled Beat. It glows with a slow pulse while the session is observed
  running and stays dim when the session is not running or its liveness is stale or unknown,
  since Beats fire only while the session runs. Reduce Motion keeps a static glow. Click it,
  or press it with VoiceOver ("Beats for this agent"), to open Beats scoped to that session;
  **New Beat** targets only it and **Show all** returns to every Beat. It never focuses the
  row or navigates CMUX. Its tooltip lists the enabled Beats by cron.
- The workspace hover shows CMUX's workspace-wide listening ports (#75), labelled
  `Ports (CMUX, workspace-wide)`: sorted port numbers, `None reported`, or `Not granted`. CMUX gives
  no owner, address, protocol or completeness, so the row never appears on an agent hover. The
  sidebar now requests CMUX's `networkPorts` read scope, so CMUX asks you to approve it again;
  existing scopes keep working until you do.

### Changed

- Interactive agent rows are one line: icon, name, tag chips, state (#58, ADR 0028). The
  subtitle with the assigned directory or activity caption is gone from those rows; both stay
  in the row's help, and the assigned directory stays in hover and details. A collapsed parent shows its spawned agents as an icon card
  instead of an active-descendant count.
- CI cancels superseded pull request runs so obsolete work no longer competes
  for macOS runners. Other PRs and in-progress `main` runs are unaffected;
  the current candidate still needs its own successful `ci-gate`.
- The global `maestro` guide prefers visible, interactive `maestro_spawn` workers
  for substantial work in managed sessions only with explicit human authorization
  to delegate to another Copilot session. Built-in `task` remains
  for short read-only work, quick reviews, and unmanaged fallback, never to bypass
  a missing managed lifecycle tool or refused launch. Maestro-launched sessions
  use identity verification, not the born-managed readiness tool. Spawn icon
  guidance now names the Nerd Fonts 3.5.1 catalog.
- Maestro spawns inherit a born-managed parent's verified launch allow-all mode
  when `yolo` is omitted, including nested children. `yolo: false` narrows; recorded
  denies survive. Exact provider PID/start-time checks retain only derived mode
  and source, never argv. CMUX-restored `--resume` / `-r` and `--session-id`
  launches qualify without inspecting persisted session state. Other unreplayed
  plugin, configuration, workspace and session selectors keep children in
  default mode; only reviewed benign launch options qualify. Runtime
  `/allow-all` changes are not observed (ADR 0006).
- Every Copilot session in a CMUX tab is Maestro-managed (#261, ADR 0025 amendment). A session
  already running when Maestro was installed enrolls in place at its next extension join
  (`/clear`, `/resume`, or an extension reload you run); Maestro never triggers one. A session the
  human resumes after `/exit` re-enrolls as the next generation of its node, or as a new root if
  the node was archived; a relaunch still never brings back an `/exit`ed session. The
  `session-started-before-install`, `enrollment-window-passed` and `session-ended` refusals are
  gone. `maestro_readiness` adds a plain-language `message` for every reason.
- A session that replaces an ended session in the same Copilot process (`/clear`, `/resume`)
  takes over the tab when the earlier session's end was recorded (#261). A root with live
  children releases the tab and keeps its run; the new root has no authority over them.
- A session enrolls once Copilot holds it, at its first prompt, never on the absence of
  Copilot's session lock (#261): two tabs resuming one session cannot both look like its owner.
  A managed root also loses authority (readiness `session-custody-lost`) as soon as another live
  process holds its session; only the next extension join restores it.
  Before then, readiness says `awaiting-first-prompt`. Refusals recorded by an earlier
  controller that this one no longer makes are decided again after the upgrade.
- Documentation-only pull requests no longer need a macOS runner (#191). The skill-override and
  policy-link checks moved to a new `validate-portable` job on Linux after a portability proof.
  The skill hash now sorts paths with an explicit en-US collation; Linux's default would report
  false drift. Changes to the merge policy still run `validate-contracts`, which reads it. Every
  other suite stays on macOS. Concurrency measurements and decisions:
  `docs/reference/ci-runner-placement.md`.
- Pull requests run only the CI suites their changes can affect (#194). A new `ci-classify` job
  classifies the exact change set with the reviewed map `scripts/ci-suite-map.json` and publishes
  each suite's selection and reason. Documentation-only changes skip the native tests and the
  guide probe; documentation images skip every suite. Anything unmapped, shared, bundled or
  unclassifiable runs everything, and `main` always runs everything. `ci-gate` accepts a skipped
  suite only with that run's complete classification marking it not applicable.
- CI ends with a `ci-gate` check, the merge signal: it passes only when every required suite
  succeeds, and fails on any failure, cancellation, skip or missing result (#197). It is a
  required status check on `main`, enforced for administrators too (owner decision 2026-10-15).
- Every CI job has a pinned job-level `timeout-minutes` hang ceiling, about three times its
  normal duration (native 60, contracts 50, probe 15, Linux jobs 10 minutes), after a setup-test
  hang held a run for about 4.5 hours. A job that hits its ceiling fails `ci-gate`. Step-level
  timeouts stay forbidden (owner decision 2026-10-15, overriding #190 for job ceilings only).
- Two intermittently hanging process-supervision tests were removed (owner decision
  2026-10-15, #174). Now untested: metadata cancelled during an in-flight exchange (its
  `.failed(.cancelled)` result and the server's exit and reaping), and non-delayed launcher
  cleanup for both timeout and cancel, the production-like path that hung in CI. Cleanup
  stays covered only with a delayed launcher; `queuedStartupDoesNotConsumeChildReadinessBudget`
  is the remaining cancel coverage. The remaining real-process supervision tests give up after
  30 seconds, recording clock, fixture-file and PID evidence, instead of waiting indefinitely.
- CI runs once per pull request update and on pushes to `main`; feature-branch pushes no longer
  run a duplicate suite. Open a draft PR to validate a branch (#192).
- The orchestration test suite runs in about half the time locally (#195). Its fixture controller
  processes no longer load the whole suite, and four resource-accounting tests fill a small
  configured workspace limit; one test still fills the default 32. Profile and next steps:
  `docs/reference/test-performance.md`.
- An expanded agent row and everything rendered under it (sub-agents, internal tasks, nested
  workers and sessions) now hover as one block: one continuous highlight behind the whole
  group, whichever row the pointer is over, with the agent's actions (…) shown. The focused
  agent's blue bar runs down the full group; collapsed, it marks just the row as before.
  Nested blocks join the outermost one, so there is never a second highlight or bar.
- Agent rows for one Copilot session show that session's name instead of the terminal title,
  which Copilot sets to "name - status". The name comes from the `name:` field of the session's
  `workspace.yaml` (ADR 0022), read only for the exact bound session, bounded and strictly
  parsed. Hover cards, details, the Active window footer, Taskboard cards and Beat targets use
  the same name. If the name is unavailable, the CMUX title shows unchanged. Managed rows keep
  their launch label; plain terminals and browsers keep the CMUX title. An automatic name can
  repeat the session's first prompt, as the terminal title already does; rename the session to
  choose its title.
- Internal tasks no longer have their own "N internal tasks" header and chevron. They show
  whenever their owning row is expanded; that row's chevron is the only collapse control.
- Make Beats store writes atomic and synced. The orchestrator now fsyncs the temporary file
  before the rename and the folder after it, and the sidebar syncs the folder after its rename,
  so a crash or OS failure can't tear the store. A failed folder sync, after the change has
  landed, is a warning rather than an error, so a retry can't repeat the change. The bytes
  written are unchanged.

- Make the Beats panel terse, and turn a Beat on or off with **Enable** and **Disable**. The
  panel has a **+** (New Beat) in its header and one-line rows: an On/Off switch, a preset
  name (Hourly, Every 15 min) or the cron, and the prompt; the row's context menu offers
  **Enable** or **Disable**. Next-run estimates (with the date beyond a week), "not running"
  and Copilot timing move to tooltips and VoiceOver values. `beats enable` and
  `beats disable` are the documented commands; `beats pause` and `beats resume` still work
  as aliases. "Resume" now means only resuming a Copilot session. Beats code comments cite
  ADR 0007, and ADR 0020 for the store location.
- Record the Beats store as the sidebar's only write grant outside its own container
  (ADR 0020, amending ADR 0001): the accepted risk that a Beat prompt becomes agent input,
  that same-user processes may edit the store, and that Beat prompts are authored
  definitions rather than observed session content. The sandbox reference lists all four
  file grants.
- Label a Beat as On or Off and its next run as an estimate. The sidebar showed "Active"
  without any confirmation from Copilot and promised exact timing ("Missed times are not
  replayed; one attempt per occurrence") that only Copilot's scheduler decides. The
  redundant `SidebarBeatStatus` is gone; `enabled` is the single source.
- Refuse a stale Beat edit in the sidebar. The form saved its cron and prompt over whatever
  the store held, so an agent's change made while the form was open was silently lost. A
  save is now refused if the Beat's cron, prompt or session changed since the form opened
  (enabling or disabling elsewhere is not a conflict); **Load latest** keeps the draft.
- Own Copilot schedules by ID, not by label. The extension treated any schedule labelled
  `Beat [<id>] …` as a Beat, so it could stop a user's look-alike schedule, and a schedule
  list without labels made it add the same Beat again every sync. It now records the IDs
  Copilot returns in a per-session ledger
  (`~/Library/Application Support/CMUXMaestroPreview/BeatSchedules/<session>.json`, outside
  every sidebar grant) and keeps or removes only those. Each add is recorded as pending
  before Copilot is asked, so a schedule created just before the extension stopped is
  adopted instead of duplicated (only an unambiguous match); shutdown waits up to two
  seconds for a sync in flight; one extension process per session owns the ledger. An
  add whose ID cannot be recorded is stopped again (or reported if it cannot be), and an
  invalid ledger changes nothing and says how to recover. Schedules made by earlier
  versions are no longer recognized, and Copilot keeps schedules across resume: stop
  leftover `Beat [` schedules with Copilot's schedule commands, or start new sessions.

### Fixed

- A failed native spawn's launch lease no longer blocks closing unrelated
  children in its run; it still fences its own node, subtree and surfaces. Native
  close/spawn release a failed lease once provider exit and surface absence are
  proven; unanchored leases stay retained. Attach confirms pane membership from
  CMUX's atomic surface inventory (#387).
- Restored click targets for animated sidebar pets.
- Active window details follow a positively verified replacement session without
  treating its retained unknown predecessor as a competing occupant. Ambiguous
  and unverified observations remain unavailable.
- Invalidated file watchers finish before requesting recovery reads, avoiding
  reads against a retired registration. The native regression fails promptly
  rather than hanging while awaiting a replacement watcher (#368).
- Repeated turns can settle idle when an interleaved background tool's start
  predates the bounded tail. Unowned completions preserve replay-checked
  envelope continuity without acquiring ownership or completing work (#352).

- Hidden finished internal tasks no longer leave empty expandable **Unknown
  agent** rows. Unprotected fragments join **+N unresolved**; the workspace eye
  restores their tasks, while protected descendants keep their ancestry (#353).
- Born-managed enrollment can reconsider an unavailable account or an earlier
  provider holder at later session events. Exact session-end callbacks received
  during extension join are retained until the managed observer is installed
  (#348). Actual interactive `/resume` callback ordering remains unverified.

- Identity hooks retire bounded batches of superseded, verified-dead Copilot
  bindings while preserving the newest ended binding per surface, resumed and
  uncertain owners, permanent locks and sanitized recovery records (#336).

- Unattributed internal activity shares one neutral unresolved indicator instead
  of repeated unknown-agent rows. Named tasks, attention and required ancestry
  remain visible; bounded history and work-state evidence stay unchanged (#341).

- Sessions no longer stay Working after Copilot restarts turn counters within
  one interaction and ends without `session.idle`. Exact turn evidence settles
  the primary state across interleaved background events, while background
  work and incomplete history stay separate (#343).
- Copilot CLI 1.0.103 no longer blocks installation on removed remote flags.
  Setup selects supported no-sync controls from runtime help, keeps older CLI
  support, and refuses unknown controls. Installer failures show only vetted
  bridge reasons instead of losing the diagnostic (#339).

- Ended managed rows focus their exact retained terminal without opening an
  unavailable Details popover. Clean verified-ended sessions on existing terminals
  revert to normal terminal rows when ended history is hidden; failures, attention
  and retained task evidence stay visible. Missing surfaces have no focus action (#337).
- Workspace rows reuse identity-and-freshness placement results across redraws
  instead of repeatedly copying session histories. Timestamp-only reads no
  longer redraw the outline within the same displayed minute; coherent display
  snapshots retain independent freshness and history deadlines. Actions and
  newly opened agent previews use current evidence; hidden previews no longer
  build their cards on every row update. Exact history-expiry wakes reuse
  unaffected session projections and process all already-due outcomes together
  without delaying retention deadlines. Unchanged observer bytes reuse resolved
  hierarchy and icons; process-only updates rematch processes without rebuilding
  those overlays. Secure reads and clock-boundary checks remain in place (#334).

- Large session logs start from a bounded recent tail rather than replaying all
  history. Sidebar settings offers **Event tail (MiB)**, default 4, range 1–64.
  New or replaced logs and large gaps after paused polling use the current value
  without restart; existing windows never backfill on a setting change. Omitted
  child history stays incomplete, and unproven current state stays unknown.
  Still-selected sessions keep replay protection across unrelated tab changes
  and temporary reader outages. At the 64-session limit, live or uncertain owners
  keep their slots; verified-dead owners release them, even when their session
  directories are missing. Historical dead bindings cannot block live admission.
  Missing files alone never evict an uncertain owner's replay evidence.
  A separate bounded ended-row cache preserves **Show ended agents** and
  **Process ended** without keeping transcript tails for dead owners.

- An unavailable session no longer hides healthy agents' current states, names,
  pets or child work. Unavailable state and verifier-unknown observations stay
  scoped to their exact session; retained status remains explicitly unknown
  rather than fresh. Other identity and permission failures remain global.

- Binding-file updates wake sidebar readers without rebuilding their watchers.
  Missing session directories no longer disable healthy watches or bindings
  notifications (#328).

- Sidebar session and managed-agent changes wake their readers through coalesced
  file notifications for shown/bound sessions, not every session on the machine.
  Binding-directory notifications are non-recursive. The two-second safety
  poll and independent freshness deadlines remain; unavailable notifications
  fall back without widening sandbox grants (#325).

- Unchanged sidebar observations no longer rebuild the session tree. Refreshed
  timestamps still reach value-based views so independent redraws retain current
  status, session names and pets. Explicit one-shot deadlines keep managed-node,
  branch-summary, Git and process freshness current even without Copilot updates;
  history expiry, future-dated evidence and observation-loss grace still advance
  independently (#321).

- Collapsed managed sessions no longer show a standalone info glyph beneath the
  row. Compact child-state and incomplete-evidence badges stay inline beside the
  session status; retained-work counts remain in tooltip and accessibility help,
  with child-history evidence in the hover card. Child summaries exclude the
  owning session's state and attention to avoid duplicate badges and counts (#322).
- Setup quiescence and session-end timing tests use controlled clocks and timers
  instead of runner-speed assertions. The CI timing guard also catches multiline
  elapsed comparisons and uptime reads (#310).
- Unchanged sidebar binding records no longer reopen and decode on every poll.
  A bounded metadata cache rechecks each file's exact identity and permissions;
  changed records still take the full verification path (#315).

- Workspace visibility eyes align with the existing session status icon column,
  including tagged rows, narrow layouts and both densities (#312).
- Sidebar pets and status cues animate in the render server instead of continuously
  relaying frames through sidebar layout. Unchanged session event files reuse their
  projection without rereading event bytes; identity checks and freshness still run.
  Title measurement and bounded orchestration decode reuse are retained (#307).
- Setup process-isolation tests no longer hang in unrelated fixture teardown.
  Exit observation is asynchronous with the full 60-second wait budget; an
  independent 70-second phase watchdog preserves diagnostics for non-cooperative
  stalls rather than consuming the CI job timeout (#302).
- Status reads preserve proven resource retirement instead of charging ended
  workers against workspace capacity again (#182). Restored or uncertain
  resources remain charged; stored history and its independent limits stay intact.
- One invalid or clock-skewed child no longer exposes unrelated child history.
  Mid-read event times remain known for activity, attention and history retention
  instead of disappearing for one refresh (#269).

- Installer recovery keeps its guard when a process-group existence probe is
  permission-denied, and releases it only after absence is proven (#276).

- Native spawn recognizes Copilot 1.0.100's session-catalog context and reasoning
  capabilities instead of silently discarding them (#152). Launch refusals name
  the failed admission check; unsupported optional choices still warn and use
  verified configured defaults. Heterogeneous optional catalog fields are
  filtered instead of rejecting unrelated model selections; oversized option
  arrays report only their type, length, and bound. Setup publishes the required
  parser before its importing adapter during upgrades and restores the adapter
  first during rollback.

- Control state no longer fills its 1 MiB cap and refuses every spawn (#280). When a node ends
  (resource-retired, terminal- or process-disappeared, launch or startup failure), its task
  text and provider executable move to a private per-node archive, `control/retired/<node-id>.json`
  (owner-only), and its launch PATH is dropped. Identity, lineage, outcome, timestamps, account,
  policy, messaging and Git counts stay, so resume, archive and the sidebar work unchanged; a
  resume uses the archived executable. Existing installs compact on their next state write.
  Archive removes a node's archive with its launch scripts. Capacity preflight adds
  `hostStateByteWarning` at 80% of the cap.

- Managed agent rows no longer offer an empty disclosure or collapsed info marker
  when their only internal tasks are hidden and counts are incomplete (#277).
  Incomplete internal-task evidence still prevents dismissing a failed worker.

- A session's child list no longer flashes its whole history, skills, and shells for a refresh
  while a sub-agent starts a tool (#264). The reader stamped the snapshot before reading, so an
  event appended mid-read looked future-dated and voided every child. Snapshots are now stamped
  after the read. Incomplete attention evidence on a session or child row is an icon with a
  tooltip, not an inline "Attention evidence incomplete" line.
- After a CMUX relaunch, a resumed Copilot session is managed again and its sidebar row shows its
  name and pet before the first prompt (#261). Copilot 1.0.98 `--resume` first joins extensions
  to a never-saved placeholder session in the same process. Maestro enrolled that placeholder,
  archived the resumed session's ended run, and then refused the real session with a misleading
  `provider-already-enrolled`. Enrollment now requires the session's saved state directory and
  Copilot's own session lock. Enrollments are serialized, and a recorded decision is never
  replaced. Until the observer can bind a resumed
  session, its row uses the name and pet of the exact session in the controller's projection
  (ADR 0022 amendment).
- Each CMUX window's Maestro sidebar shows only its own window. Opening a second window no
  longer replaces the first window's workspaces, and focus or actions in one window no
  longer reach another (ADR 0023). A reviewed patch to the pinned SDK, applied by
  `scripts/fetch-sdk.sh`, keeps one connection per window instead of replacing the
  previous one; each sidebar view owns its own state. If ExtensionKit shares one scene
  across windows, both say "This window's CMUX connection is unavailable" until one
  closes, rather than showing the wrong window. Beat row icons keep each window's
  liveness, and the Beats panel opens only in the window that asked for it.
- Make every Beats reader apply one store contract. The Swift sidebar and the orchestrator
  now refuse the same stores (shared `scripts/test-fixtures/beats-store-cases.json`):
  `true`, `1.0` or out-of-range integers, uppercase UUIDs, non-text timestamps, lone
  surrogates, `NaN`, U+FEFF anywhere, whitespace-only prompts (U+200B counts as whitespace),
  and a store file or folder readable by others. The
  installed extension no longer parses `beats.json`; it asks the controller
  (`beats-snapshot`, read-only under the shared lock) for its session's runnable Beats, and
  an invalid store now leaves Copilot schedules untouched instead of silently dropping a
  Beat and stopping its schedule.
- Write the Beats store as UTF-8 from the orchestrator too. It escaped non-ASCII text
  (`\u00e9`, up to 6 bytes a character), so a store the sidebar saved under 1 MiB could
  exceed the limit when re-encoded and block even `beats list`. Both writers now produce
  byte-identical files.
- **Breaking:** make a Beat simply on or off, as ADR 0007 decided. The Beats store is now version 2:
  `recoveryGate`, `targetEnded` and `lastFiredMinute` are gone, with the unused Maestro
  clock (`beats_due`), the unreachable `beats gate-session` command, and the sidebar's
  "Needs recovery", "Target ended" and **Re-enable** states. Moving a Beat to another
  session keeps it on or off, and an agent's `beats enable` always turns it on. A version 1
  store reads as empty and is replaced on the next write; its Beats are not migrated.
  Every store must also be plain JSON for both readers: unique keys, Int64 integers only,
  Unicode text and at most 8 nested levels, so a duplicate `version` can no longer make
  the sidebar and the orchestrator read different versions.
- Key each Copilot schedule by the full Beat ID (`Beat [<id>] …`). The extension matched
  only the first 8 characters, so two Beats sharing a prefix collapsed into one schedule
  and the second never ran. Schedules with the old 8-character label are removed on the
  next sync and re-added under the full ID, so nothing fires twice.
- Keep one Beat's failure from blocking the rest. When Copilot rejected one schedule, the
  extension stopped the sync there, so every later Beat in that session never registered,
  and it logged a single generic diagnostic. Each schedule change is now attempted on its
  own, and a failure is logged once per Beat (with its ID) until it succeeds.
- Apply a disable or edit noticed during a sync from the newest store. The change-triggered
  sync was dropped while one ran, so a sync that had already read the store could register
  a just-disabled Beat and leave it until the next poll. A sync requested mid-run now stops
  the running pass from starting further changes and reruns it, and no schedule change
  starts after the session's Beats are closed.
- Follow a Mac time zone change in a running session. The extension fixed its zone when
  the session started (and Node caches the zone anyway), so Beats kept firing in the old
  zone. Each sync now uses an IANA zone name in `TZ` when set, else reads the
  current zone from `/etc/localtime` (falling back to the runtime's zone), and re-registers
  Beats when it changes.
- Preview stepped day fields the way Copilot fires them. A day-of-month or weekday field
  such as `*/2` was treated as "any day", so `0 0 */2 * *` previewed every day and
  `0 0 */2 * 1` previewed Mondays only, while Copilot runs odd days, and odd days or
  Mondays. Only a bare `*` is unrestricted now; previews in the sidebar and `cron-check`
  match next runs recorded from Copilot's scheduler (outside daylight-saving changes;
  re-check with `scripts/check-copilot-cron-oracle.mjs`). A bare `*` inside a list (`*,5`),
  which Copilot refuses, is now refused when saving instead of silently never firing.
- Let any Copilot agent in CMUX make its own pet: `maestro-pet` now ships a
  dependency-free `pet_kit.py` drawing kit instead of requiring `hatch-pet`, whose
  Codex-only image generation was unavailable to Copilot.
- Remove the orchestrator's testing mode. `CMUX_MAESTRO_TESTING` and the test-only root,
  executable, timeout, identity-helper and attach-fault variables are ignored; worker
  admission never skips its parent-evidence check. Worker Copilot processes receive only the
  controller's own `CMUX_MAESTRO_` variables: the bounded environment drops every inherited
  one, and a direct launch execs the provider through a controller bootstrap that rebuilds
  the environment without any other `CMUX_MAESTRO_` name, including names that are not
  shell identifiers.
- Stop a sub-agent's model change from replacing the session's model in the footer and
  previews (a Copilot `session.model_change` event carrying a sub-agent ID now updates only
  that sub-agent).
- Show the chosen pet in the Active window footer. The footer never passed its agent's
  session to the pet picker, so every agent showed the default pet and the picker said
  "This item has no agent session".
- Hide the expand arrow on an agent row when its only sub-tasks are finished and hidden.
- Stop the sidebar flashing a list of finished shell and skill rows (each marked "Attention
  evidence incomplete") while an agent runs sub-agents; momentarily incomplete evidence no
  longer revives finished activity or marks task rows.
- Accept any Codex pet sheet with 8 columns and at least nine rows of 192:208 cells at any
  whole-pixel scale, including **v2** pets (1536×2288, with look-direction rows), in both
  `maestro pet --add` and the picker. Maestro plays only the first nine rows and ignores the
  rest. Previously such pets were rejected as "must be exactly 1536×1872".

### Fixed

- Stop the Active window footer jumping up and straight back when you click a row. The
  navigation status line ("Selecting…") sat below the footer and pushed it up until the
  selection finished; it now floats above the footer instead.

### Added

- Collect pets like a Pokédex. Hover the footer pet while an agent uses an agent-made pet to get a
  **+** badge that saves it to your shared pets; the picker also shows a **+** on agent-made pets and
  an **×** on collected ones (with a confirmation) and counts how many you have collected. Every
  agent's picker shows the whole collection.

### Changed

- Rewrite the README as a short overview with screenshots and an install path. Move the full
  contracts, unchanged in substance, to `docs/reference/`. Add `CONTEXT.md` (domain terms),
  `docs/adr/` (19 decision records), and an evidence and safety rules section in `AGENTS.md`.
- Internal-task rows put their state spinner on the left and hide the counts on the
  collapsed row; finished tasks stay hidden until the workspace eye is on. The expand
  chevron is narrower, and "Error reported" no longer shows on an agent that is still
  working.
- Rebuild the Taskboard as a state board: one card per agent session under **Waiting on
  you**, **Working**, **Failed**, **Idle**, **Finished** and **Unknown** headings with
  counts. Each card shows the title, activity, workspace, model and, when the agent is in a
  git repository or linked worktree, its branch. Sub-agent, skill, shell and internal-task
  rows are no longer listed there; Hierarchy keeps them.
- Show a small, always-visible copy icon beside every detail label (including the model in
  the preview). A successful copy shows no "Copied" text; the icon turns into a checkmark.
- Add more padding between Taskboard cards.
- Remove the "Active window" heading and the "Details" button from the footer: clicking the
  agent's title now opens the details popover. Preview cards size themselves to their content
  (scrolling only when taller than the screen), with the rename note at the bottom right.
- Give the workspace preview the same copy icons (surfaces, paths, workspace ID) and drop its "Preview only" footer.
- Let the active-window footer be resized: drag the divider above it. It can shrink to
  just the pet row and grow to half the sidebar height; the size is remembered, and
  double-clicking the divider restores the automatic size.
- Add **Rename… (⇧⌘R)** to the workspace menu and a "⇧⌘R to rename" note to the workspace
  preview. CMUX exposes no rename action to extensions, so the menu item selects the
  workspace and shows a short reminder of CMUX's own shortcut.

### Removed

- Remove the sidebar's Work context section (#259). An ended or archived run leaves no row:
  a registration whose surface now holds a verified different session and its old
  observation no longer stay on screen for context or unread attention, and a session on
  another agent's surface gets no row of its own. A live descendant of an ended agent shows as a normal,
  focusable row without the ancestor.
- Drop the reusable, movable content-tab concept. Taskboard stays a sidebar-only view
  toggled from the header, and the visual proof of concept now matches (Beats is a
  popover; no utility tabs). Closes #86 and #87 as not planned.
- Remove the header History shortcut: it opened the same popover as Maestro settings,
  scrolled to the completed-work controls, which remain in Settings. The header now has
  four shortcuts.

### Changed

- Stop showing failed nested shell commands ("bash invocation · Shell · error") as red
  outline rows. They move to the session's Other activity disclosure; blocked or
  attention-bearing shell rows and failed agents/tasks still stay visible.

### Added

- Show the git branch each agent is working in on its Taskboard card (a linked worktree
  adds a `· worktree` suffix and icon) instead of the terminal directory; no row appears
  outside a repository. The Copilot hook now also publishes only the branch and a worktree
  flag per session in `Copilot/locations/`, read from the hook `cwd` and tool path by
  reading `.git` files directly (no `git` process, no paths or repository names recorded).
- Add Beats: recurring cron prompts for exact agent sessions. A native sidebar popover
  manages them (the header icon lights while one is enabled), `/maestro` agents manage
  their own through `beats`. The installed extension mirrors each session's enabled Beats
  into Copilot's native cron scheduler (any CMUX Copilot session; no clock or managed
  launch) behind an isolated `createScheduleGateway`; a Beat is simply on or off and its
  session re-registers it on start. Add the `Beats/` read-write sandbox grant.
- Show an animated Codex-format pet (1536×1872, 8×9 cells) in pinned details,
  with a bundled original Maestro robot-head default, a per-agent picker,
  **Upload pet…**, gallery links, **Save to my pets** and **Reset to agent's
  pet**. Add the bundled `maestro-pet` skill (wraps `hatch-pet`) and the
  `pets`/`pet` orchestrator commands so an agent can add and choose a pet for its
  own session after native ownership proof; agent-made pets are session-scoped
  until saved. Add the `files.user-selected.read-only` sandbox entitlement for the
  upload picker.
- Open a directory as a new workspace from the header folder action, through the
  new `createWorkspace`/`createWorkspaceWithPath` action scopes.
- Add the repository-owned `wrap-up` skill: freeze scope, true-up with main, pass
  every gate, reconcile docs and the visual POC, and deliver one undrafted PR.
- Report the exact owned target, operation, installer stage and expected/observed
  presence when LaunchServices verification fails; distinguish unknown query
  state without exposing other registered paths or adding retries. Diagnostic
  improvement only; the original installation failure remains unresolved (#185).
- Install the `pull-request` and `create-pull-request` skills project-locally and
  require agents to use `/pull-request` for PR bodies (what/why/how, evidence,
  blast radius).
- Expose bounded own-session readiness diagnostics in ordinary CMUX conversations
  without enabling managed tools, inspecting private bindings, or enrolling the
  session. Report unverified placement and absent/incomplete launcher inputs;
  in-place Joe activation remains blocked (partial #162).
- Read the responding managed session's current model, context tier and effort
  through optional identity observation, with explicit unavailable reasons and
  no launch-default substitution or model changes (#152).
- Request optional per-launch model, context tier and reasoning effort using
  bounded session-scoped capability evidence, with visible configured fallback
  for unsupported preferences and refusal of unsafe or foreign evidence.
  Configured arguments remain distinct from observed provider settings (#154).
- Configure per-workspace launch capacity from 1 to 128 (default 32) through
  an authenticated coordinator CLI, with advisory usage/preflight and exact
  root, worker, retained-resource and pending-lease accounting. Preserve
  existing lock budgets and independent node/depth bounds (#154).
- Show read-only global Maestro guide-content status in Settings > CLI Integration,
  with explicit Re-check, build-relative matching and read/copy feedback.
  Keep installation and updates manual through the existing copyable command;
  guide status does not imply runtime or messaging readiness (#55).
- Request one exact owned child-terminal close through stock CMUX, preserving
  private ownership and launch guards. Return request acceptance without waiting
  for removal, retrying, shutting down the provider, or releasing capacity; inherit
  stock host refusals, including last-terminal refusal (#90).
- Add explicitly authorized descendant-first subtree close with one fixed private
  selection, independent continuation after refusal or uncertainty, and complete
  bounded per-target results. Select the stock host's documented noninteractive
  branch on the initial admitted request, not as a retry or fallback. Preserve
  default target-only receipt/scope, ancestry and
  resource accounting; refuse unrepresentable numeric identities before effects,
  preserve results after malformed host replies, and distinguish pre-dispatch
  refusal from unknown dispatched requests. Preserve prior results when an
  invoking worker loses its stored session identity. Report `confirmation_required`
  without forced fallback
  (#91).
- Versioned visual-design references for #57, including the frozen September
  29 prototype, approved contract, 56-state synthetic review gallery and
  current ticket handoff (#134). Preserve earlier evidence and distinguish
  the approved target from native delivery and current feature readiness.
- Add label-owned copy actions for permitted raw session, observation,
  child-history and path values in agent previews and pinned details,
  preserving provenance, keyboard access and explicit clipboard feedback
  (#112).

### Changed

- Show a pending question as a slowly pulsing light-blue question-mark badge and
  row tint instead of a spinner, an error-colored label or a "Waiting for
  answer" line; remove the redundant global and workspace-level needs-input
  summaries. Show turn finished as a checkmark badge instead of a text line.
- Default prospective Joe/Maestro Developer workers to gray, retaining the
  bicep icon, explicit human overrides and all other role defaults. Existing
  sessions are unchanged (#164).
- Default local Joe/Maestro delivery, review, test and investigation workers to
  short-lived assignments, with exact evidence and accepted duty custody before
  separately authorized owned close. Retain concrete duties rather than idle
  pools; preserve work and distinguish close acceptance from removal or capacity
  release (#165).
- Use one local Joe role-appearance mapping for prospective launches and
  handoffs, applying the requested Roast, PR Sniper and Shepherd glyphs while
  preserving explicit human choices and existing unspecified colors. Separate
  human staffing budgets from installed and source capacity limits (#164).
- Isolate stored-node admission and retired history by CMUX workspace, retaining
  128 nodes per workspace and distinct bounded host/storage protection. Keep
  multi-workspace saved-state, messaging routes and sidebar projections valid,
  with equivalent UUID spellings sharing one allowance, without resetting,
  pruning or changing another workspace's sessions; activation remains an
  explicitly authorized upgrade (#167).
- Preflight Joe launches against both live workspace and global node capacity;
  honor current scoped staffing, model-default and new-worker permission choices
  without repeating routine authorization interviews (#154).
- Inherit explicit recorded parent launch permissions for prospective native
  children, preserving denies, narrowing and provenance/drift refusals. Current
  provider-policy equivalence and actual restricted startup remain unverified
  (#154).
- Target two-hour Joe deliveries without skipping gates. Select doctrines before
  review/self-checks, keep one PR-state contract, and check local skill hashes/links.
- Raise the default per-workspace limit from 8 to 32 live managed sessions,
  including managed coordinators and retained resources, without changing
  launch accounting or the 128-node and eight-level nesting limits. Validate
  immutable read snapshots outside the shared lock so readers do not block
  writers during decoding and validation, and share read-only runtime ticket
  lookups. Scale bounded lock-acquisition budgets against the fixed 32-session reference,
  retaining exclusive mutations, failure on exhaustion and launch/result deadlines.
- Attempt Copilot integration with stable CLI 1.x releases on protocol 3 instead
  of an exact-release whitelist. Preserve source ownership, disabled-state
  readback and transaction guards; report incompatible version/protocol pairs.

- Constrain the working long-identity action-menu reference to the viewport,
  preserving complete accessible names and keyboard-reachable actions (#132).
- Guide native Maestro coordinators and workers to send compact milestone-only
  handoffs, yield between decisions, and reconcile current-candidate evidence
  without losing unresolved findings. Preserve fire-and-forget messaging and
  independent delivery gates (#142).
- Match internal-task headings to the approved prototype without inline
  completeness diagnostics, preserving counts, task visibility and detail hints.
- Show internal Copilot tasks as compact, non-interactive lines with
  workspace-local visibility, persistent disclosure, and exact-outcome
  dismissal that preserves local keyboard focus (#131).
- Coordinate updates to the recognized Maestro app and its Copilot CLI
  1.0.88/1.0.89 integration, verify identical reinstalls, and recover prior owned
  state after failed or interrupted publication. Bind ownership through public
  provider results, restore supported disable choices before publication, and
  preserve unrelated plugins. Gracefully restore the exact containing app
  without activation; do not restart existing Copilot sessions. Retain one
  inactive app for recovery, and report conflicting native registrations before
  changing the installed app. Registration status describes owned state, not
  provider-wide uniqueness or loaded-session behavior (#114).
- Route live Copilot observations through the existing provider-neutral session
  snapshot, preserving lifecycle/liveness distinctions, partial ancestry,
  history and attention behavior. Retain v1 decoding and nested validation,
  checking neutral evidence before history filtering without adding control
  capabilities (#10).
- Commit project-local skill files, references, helpers, and upstream notices
  alongside the lockfile so a checkout includes the reviewed skill set.
- Standardize repository agents on upstream CMUX and refreshed personal skills,
  excluding the Orca coordinator.
- Use all open GitHub Issues in `jdylanmc/cmux-maestro` as the default backlog,
  with explicit issue or epic narrowing.

### Removed

- Remove the Fermata header placeholder: CMUX exposes no keep-awake control to
  sidebar extensions.

### Fixed

- Detect pending questions again: current Copilot builds emit no
  `user_input.requested` event, so an in-flight `ask_user` call now counts as a
  pending answer until it completes.
- Share wrapping Git summaries across agent hover cards and pinned details, with
  accessible green additions/red deletions and unchanged assigned-directory,
  freshness and comparison semantics (#80).
- Remove the redundant `Agent` subtitle prefix so existing location and activity
  have more room, preserving status, full location help and non-agent labels (#188).
- Request native in-turn steering for managed peer messages instead of waiting
  for the current turn to finish; preserve legacy proof enqueue and
  fire-and-forget limits (#163).
- Refresh lazy preference state when its registered ancestor directory changes,
  preserving read-only initialization and unrelated subitem filtering (#169).
- Keep valid provider-native reasoning defaults from blocking unrelated model
  selection; omit unrepresentable CLI defaults while retaining malformed-data
  refusal and warned provider-default behavior (#154).
- Allow bounded finite child narrowing from recorded YOLO without redundant
  parent allow rules, preserving denies, default-parent and escalation guards
  (#154).
- Clean up failed orchestration-test fixture registration through the existing
  quiescence protocol, retaining evidence and both errors when cleanup cannot
  complete (#154).
- Align the historical-session dismissal fixture's clocks; keep production
  stale-action rejection and native dismissal/focus assertions unchanged.
- Remove synthetic background-shell rows and their associated outcome notices,
  preserving worker/task errors and distinct shell tool invocations (#155).
- Show explicit unavailable or last-reported model text for the exact observed
  agent, without borrowing another session's model (#74).
- Qualify managed Git labels, verification and change counts as evidence from
  the assigned directory, not Copilot's current `/cwd`, preserving stale and
  unavailable states and separate CMUX surface-directory reports (#119, #59).
- Keep exact-chat visual status through temporary observation gaps for five
  minutes, then quietly show Status unavailable without retaining control
  authority; preserve real background tabs and internal-task parents (#119).
- Start managed Copilot terminals directly with verbatim Maestro-wrapped tasks,
  return acceptance without a startup wait, and derive activity from fresh exact
  session observations. Preserve messaging across normal extension reloads and
  retain uncertain launch ownership without retries or guessed cleanup (#61).
- Qualify agent and child directories as CMUX surface or parent-surface reports,
  with explicit source and report-age limits, preserving exact placement, path
  permissions and home-relative display (#77).
- Start setup-test fixture readiness after installer spawn rather than task
  enqueue, preserving timeout, cancellation and process-cleanup checks.
- Stabilize offscreen focus-layout fixtures with owned overlay/legacy-equivalent
  content widths, retaining real-native scroller coverage and detection of
  genuine geometry changes (#127). Sample applied native style transitions
  before later recommendations, isolate cross-process observation from AppKit
  rendering, and control lifecycle-fixture clocks without changing production
  timing or test deadlines. Capture bounded metadata-test stall diagnostics
  without masking failures or claiming the underlying hang is repaired.
- Automatically omit unneeded old managed registrations when an exact current
  replacement is verified. Preserve ancestors and original-session context
  needed by work or unresolved attention, without deleting records or closing
  terminals and sessions.
- Keep a replacement session's working or idle status visible when ended agents
  are shown, without duplicating retained managed identities or hiding their
  descendants and attention (#111).
- Keep Copilot session observation current across valid oversized tool, message,
  model and asset payloads, including metadata maps, using bounded metadata-only
  projection with exact completion attribution and explicit degradation for
  malformed history (#121).
- Preserve observed child names, kinds and ancestry on explicitly configured
  Copilot multi-turn continuations, without letting old spawn outcomes finish
  the new interaction. Match observed message interaction/turn metadata to
  restore Idle after interleaved follow-up completion; missing or contradictory
  proof still reports Unknown. This fixes demonstrated continuation behavior,
  not every Unknown agent or all of #118.
- Preserve managed-session custody through failed startup and partial storage
  publication; allow safe failed or exited managed roots to archive without a
  surviving tab, and keep moved terminals counted against the live-resource
  limit using atomic host inventory (#64).
