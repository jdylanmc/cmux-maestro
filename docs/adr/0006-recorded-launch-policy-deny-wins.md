# Recorded launch policy, deny wins

Child launches use the parent's recorded policy: mode, bounded allow rules, deny rules. Denies win, descendants never widen inherited permissions, explicit worker YOLO refuses, and coordinator YOLO needs explicit human approval. The record is history, not proof of live permissions.

Why: the Copilot SDK offers no atomic, verified view of live permissions. Pretending to inherit them would be a guess.

Rejected: a live permission snapshot, mutating permissions after launch, granting shell or wildcard rules from tool visibility or prompt text.

Consequence: `/permissions` or `COPILOT_ALLOW_ALL` can make a record stale. Flags are policy, not an OS sandbox.

## Amendment (2026-10-19): inherit verified parent allow-all

Owner decision: "I want maestro to spawn agents with yolo if the current agent has yolo."

Born-managed roots now derive their launch mode from their exact bound provider
PID, after session custody and enrollment identity checks. Read NUL-delimited
argv once per observation, using macOS `KERN_PROCARGS2` (Linux `/proc` in portable
controller tests), checking the recorded process start time before and after.
No lock file alone selects a provider. Store only `permissionMode` and
`permissionSource`, never argv, prompt text, or environment. This is a narrow
exception to the no-observed-content read rule, not permission to retain content.

`--yolo`, `--allow-all`, or all of `--allow-all-tools`, `--allow-all-paths`, and `--allow-all-urls`
prove launch allow-all, including `=true` forms. False/unknown boolean values
do not. Argument values and text after `--` are not flags. A deny flag not
already covered by the recorded tool policy prevents inherited allow-all:
do not discard an unrecorded manual deny or persist it from argv.
Unavailable argv or changed PID identity never proves allow-all.
All other options default unless explicitly admitted by the controller's small
`benign_value_flags` / `benign_other_flags` allowlists. Required argument values
cannot become permission flags; optional arguments such as `--share` never
swallow following options. This is an allowlist, not an expanding list of known
bad flags: an unreviewed option cannot prove unrestricted inheritance.

Admitted values are prompt/attachment data, name, model/context/reasoning
selection, output/logging, and execution budgets. Other admitted flags affect
presentation, only widen tool/URL access, remove instruction/shell setup,
control updating, or select autopilot. `--experimental` is also admitted because
managed children already replay it. Neither prompt contents nor instruction
files are permission evidence.

Unreplayed loaders/selectors therefore default, including:

- Code/configuration: `--agent`, `--config-dir`, `--plugin-dir`,
  `--extension-sdk-path`, `--additional-mcp-config`, `--add-dir`, `-C`,
  `--bash-env`, `--dynamic-retrieval`, `--enable-memory`,
  `--allow-all-mcp-server-instructions`.
- Existing or alternate session state: `--session-id`, `--resume`, `-r`,
  `--continue`, `--connect`, `--acp`, `--remote`, `--remote-export`,
  `--no-remote`, `--no-remote-export`, `--fleet`.
- Tool/environment/mode selection: `--add-github-mcp-toolset`,
  `--add-github-mcp-tool`, `--mcp-github-auth`, `--enable-mcp-server`, `--mode`,
  `--plan`, `--secret-env-vars`, `--no-ask-user`, `--no-experimental`.
- Restrictions: `--assisted-approval`, `--disallow-temp-dir`,
  `--available-tools`, `--excluded-tools`, `--disable-mcp-server`,
  `--disable-builtin-mcps`, unrecorded `--deny-tool`, and other `--deny-*`.

Unknown selectors such as `--profile` default too. Bare optional selectors also
default: they may load persisted state. Thus a born root explicitly launched
with `--resume` or `--session-id` no longer proves inherited allow-all from argv
alone, even when `--yolo` is also present. Maestro-launched descendants still
replay their recorded policy. This deliberately narrows implicit inheritance;
the separately human-approved coordinator grant remains available.
Maestro never reads plugin, agent, configuration or resumed-session definitions
to try to prove them unrestricted.

Safety correction to the initial two-category design: Copilot documents
`--allow-all` as tools **and paths and URLs**. Tools plus paths alone cannot
be replayed as `--allow-all` without widening URL access, so they stay default.
This prioritizes the owner's non-escalation requirement over that shortcut.

Enrollment and re-enrollment record the derived mode with source `launch-flags`,
or default with source `unverified`. Spawn refreshes born-parent evidence,
including roots enrolled before this amendment, and rechecks provider identity
at reservation. Maestro-launched descendants retain the existing recorded-policy
contract. Omitted `yolo` and `allowTools` inherit the verified/recorded parent mode,
for both coordinators and workers. Denies still replay. `yolo: false` or an
explicit allow-list narrows to default. The result reports effective requested
`permissionMode` and `permissionSource`; it does not attest to live child settings.
Children record the inherited mode so grandchildren inherit it too.

Explicit `yolo: true` retains the separate existing human-approved coordinator
grant; it is not implicit inheritance and still refuses from workers before
credentials or reservation. Default/unverified parents never gain allow-all
through omission. Missing recorded tool-policy provenance still refuses.

Known limit: runtime `/allow-all` toggles are not visible in argv or usable
events. An argv-default parent is treated as not-YOLO even if toggled on later;
an argv-YOLO parent toggled off cannot be distinguished from its launch mode.
Configuration/environment permissions are also not a verified snapshot.
No persistent Copilot settings change, prompt approval, or live-session control.
