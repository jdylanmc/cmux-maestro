# Changelog

Notable changes are recorded using Keep a Changelog categories.

## Unreleased

### Fixed

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
  session keeps it on or off, and an agent's `beats resume` always resumes. A version 1
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
- Apply a pause or edit noticed during a sync from the newest store. The change-triggered
  sync was dropped while one ran, so a sync that had already read the store could register
  a just-paused Beat and leave it until the next poll. A sync requested mid-run now stops
  the running pass from starting further changes and reruns it, and no schedule change
  starts after the session's Beats are closed.
- Follow a Mac time zone change in a running session. The extension fixed its zone when
  the session started (and Node caches the zone anyway), so Beats kept firing in the old
  zone. Each sync now uses an IANA zone name in `TZ` when set, else reads the
  current zone from `/etc/localtime` (falling back to the runtime's zone), and re-registers
  Beats when it changes.
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
