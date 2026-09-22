# Native messaging: architecture and research findings

This guide preserves Maestro's public research. Comparisons are **pinned source evidence**, not
tests of those products' installed behavior. Maestro's separate live observations
and outstanding acceptance are recorded in [delivery findings](delivery-proof.md).
Nothing here requires access to private research artifacts.

## What the upstream systems actually do

### Orca: durable mailbox, two different attention paths

At `33ba1ff3df247652c546985201d9a6f4edaec80b`, Orca persists mail before notifying
the recipient. Its notification is a pointer telling the agent to check mail;
the complete body arrives through the subsequent CLI/tool result.
The terminal path writes into a pseudoterminal (PTY) and separately submits Enter.
The structured path instead journals a user message and dispatches it through an
Orca-owned provider session. These are not interchangeable transports.
See [staging][orca-stage], [submission][orca-submit], [structured delivery][orca-structured], [notification][orca-notify].

The structured adapter router contains Claude and Codex, not Copilot
([router][orca-router]). Orca therefore does not demonstrate injection-free
delivery into an arbitrary existing Copilot terminal. Its durable mailbox and
separate acknowledgements are useful contrasts, not features Maestro needs to
copy: Orca itself distinguishes durable enqueue from attention, reading and
completion ([delivery contract][orca-contract]).

### Paseo: daemon-owned provider sessions, including Copilot over ACP

At `2c8e8a826810337492cc5a38bb0bbd705b6fb632`, Paseo's daemon owns agent runtimes.
An agent tool dispatches a prompt; a daemon watcher can notify the caller through provider input,
not a UI notification or Model Context Protocol server push into the model
([watcher][paseo-watcher]).

Copilot runs as `copilot --acp`, using Agent Client Protocol (ACP) with piped
stdin/stdout ([adapter][paseo-copilot], [process launch][paseo-spawn]).
This establishes focus-independent orchestration for daemon-managed sessions,
not attachment to arbitrary human-operated native terminals. Ordinary dispatch
can replace active work; steering also has fallback behavior
([send][paseo-send], [steering][paseo-steer]). Maestro imports none of these mechanisms.

### Herdr: identity reporting is not its message delivery channel

At `28360107c1bfab57fb0de99d74bfa48e74423ca8`, Herdr's Copilot hook reports native
session identity to Herdr ([hook][herdr-hook]). Cross-agent prompt delivery uses
the recipient terminal: text, delay, then Enter. Copilot additionally receives a
synthetic focus-gained terminal event ([prompt path][herdr-prompt],
[Copilot handling][herdr-focus]). That is input injection even without activating
an operating-system window.

Ordered terminal writes do not establish safe coexistence with a human's unsent
draft. Status waiting and terminal readback are also not exact request/reply
correlation ([wait contract][herdr-wait]). Identity observation is distinct from model-context delivery.

### Upstream CMUX: background transport is not a draft-safe mailbox

At `aa4cc90348b96c2d087e6c5e9dee4b6756891bc4`, CMUX provides explicit terminal
targets, improved runtime binding, and background text/key delivery
([binding][cmux-binding], [send implementation][cmux-send]).
The sidebar SDK has no terminal-input messaging action ([actions][cmux-actions], [host][cmux-host]).

The original terminal-injection investigation found no atomic send-if-unfocused
operation in the inspected interfaces. Separate focus observation and send would
race; buffered input does not preserve a provider's draft, and the mobile-chat
path explicitly clears input ([input replay][cmux-replay],
[mobile chat][cmux-mobile]). Those findings remain valid for terminal injection,
but **the proposed focus-gate host patch is no longer needed for this feature**:
Maestro now delivers through Copilot's native conversation API, not CMUX input.
No host fork, foreground gate, or sidebar rewrite follows from this decision.

## Chosen Maestro contract

```text
agent A: maestro_send(destination, body)
  -> A's CLI-owned adapter supplies its bound sender/return address
  -> one bounded local Unix-socket write
  -> B's adapter validates destination, sender and current bindings
  -> B's CLI-owned session.send({ prompt, mode: "enqueue" })
```

Each participating session joins its own CLI conversation through
`joinSession({ tools })` and owns one private socket; there is no standalone
broker or second authenticated Copilot client. Discovery exposes participating
same-workspace peers, not availability. Installed addresses contain exact
workspace/session identities and generation; replies use the envelope's bound
sender address, never an address asserted inside the untrusted message body.
Peer messaging grants no ancestor-only lifecycle or process-control privileges.

Copilot owns scheduling. Maestro adds no receipt, acknowledgement, retry,
completion tracker or custom busy scheduler. A local-write result is not delivery,
consumption or task-success evidence; offline/stale/unsupported recipients can
fail, and an uncertain result is not proof that nothing arrived.
Bodies are bounded to 4 KiB UTF-8 and frames to 8 KiB. Private bindings and sender
capabilities enforce local routing, but this is a **same-OS-user trust boundary**:
a malicious process running as that user can read private files. It is not an
OS sandbox or a cryptographic identity claim against that user.

## Installed lifecycle and permissions

Explicit production setup installs the native loader, shared adapter, local
controller and lifecycle/icon plugin skills. The global `/maestro` guide is
distributed separately through human-run `npx skills`; native Settings >
CLI Integration only presents and copies the command. Neither guide installation
nor availability is a runtime prerequisite. The loader is inert without matching launcher
bindings. Newly Maestro-launched visible interactive sessions participate
automatically; existing/unmanaged sessions are neither adopted nor restarted.
A coordinator without a launcher-bound session cannot receive; the sidebar sees no bodies or secrets.

The launcher retains the configured account/model pins and normal terminal I/O.
Native extension trust/tool prompts remain Copilot-owned. Defaults add no grants;
explicit user-approved coordinator `--yolo` launches may use `--allow-all` while
preserving denies. Worker actors cannot request YOLO for descendants; the reviewed
proof bypass was fixed before credential lookup/reservation. No full parent
permission inheritance, auto-approval callback, or persistent policy rewrite is
inferred. Cleanup must follow exact lifecycle ownership, not a guessed idle state.

## Evidence, corrected assumptions, and remaining gap

Initial SDK inspection used npm Copilot **1.0.83**; live sessions reported
**1.0.87-0**. Source declarations justified an experiment, not a compatibility or
draft-safety guarantee. The native proof demonstrated agent-authored A -> B -> A.
The human explicitly confirmed an unsent draft remained exact and editable.
Separate harness-origin injection demonstrated app-background response; it was
not an agent-authored send and not a sidebar-hidden test.

Installed revision `93d6968`, normal updater and human-enabled integration then
supported three fresh ordinary-working-directory participants: A discovered B
and C with generations, and A -> B -> A returned `installed-violet-54-1`.
CMUX's **Default sidebar** was selected. This disproves a dependency on the Maestro
sidebar being selected, not all visibility conditions or reliable delivery.
Mocked transport/setup tests and packaging checks do not prove native UI behavior.

Plugin-based guide discovery failed live: bare-name lookup failed in interactive
sessions despite later read-only discovery listing the skill; qualified lookup
also failed. Explicit `--plugin-dir` did not fix the live failure. No exact
upstream cause is claimed, and neither workaround remains in the launcher.

At `2026-09-22T12:03:56.533Z`, the user reported successful global local-source
installation with `npx skills` **1.5.26** to `~/.agents/skills/maestro`, followed
by successful Copilot global discovery. Global `npx skills` is now the sole guide
distribution: `/maestro` or `{"skill":"maestro"}`. This is observed discovery,
not a guarantee across CLI versions or proof of every live messaging condition.
The GitHub-source command in Settings requires the skill to merge to `main`;
[local-source acceptance instructions](../README.md#cli-integration-install-the-global-guide)
cover development without movable refs or automatic installation.

Setup writes only `{version, routes, extension}` for messaging; the old
`pluginDirectory` field is ignored if encountered. On explicit setup only,
the obsolete messaging guide in the installer's own plugin is removed, preserving
unrelated and global skills. No live files were changed for this correction.
Installed Settings UI acceptance and any consentful refresh remain separate from
the already observed global discovery success.

[orca-stage]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/mailbox-pointer-stage.ts#L97-L109
[orca-submit]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/mailbox-pointer-submit.ts#L102-L128
[orca-structured]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/structured-mailbox-pointer-delivery.ts#L215-L252
[orca-notify]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/mailbox-notification-coordinator.ts#L48-L75
[orca-router]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/structured-agent-session-runtime.ts#L288-L298
[orca-contract]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/skill-guides/orchestration/references/messaging-and-gates.md#L6-L8
[paseo-watcher]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/agent-prompt.ts#L428-L574
[paseo-copilot]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/providers/copilot-acp-agent.ts#L81-L96
[paseo-spawn]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/providers/acp-agent.ts#L2700-L2763
[paseo-send]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/agent-prompt.ts#L306-L338
[paseo-steer]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/agent-manager.ts#L2635-L2775
[herdr-hook]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/integration/assets/copilot/herdr-agent-state.sh#L53-L92
[herdr-prompt]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/app/api/agents.rs#L111-L215
[herdr-focus]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/app/api/agents.rs#L650-L687
[herdr-wait]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/app/api/agents.rs#L218-L257
[cmux-binding]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Sources/TerminalController%2BControlTerminalBinding.swift#L7-L50
[cmux-send]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Sources/TerminalController%2BControlSurfaceContext3.swift#L260-L366
[cmux-actions]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarAction.swift#L10-L26
[cmux-host]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CmuxSidebarHost.swift#L84-L90
[cmux-replay]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface%2BInput.swift#L869-L963
[cmux-mobile]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Sources/TerminalController%2BMobileChat.swift#L261-L336
