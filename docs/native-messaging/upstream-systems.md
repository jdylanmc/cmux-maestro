# Native messaging: what the upstream systems do

Part of [native messaging: architecture and research findings](../native-messaging-architecture.md). Next page is [Chosen Maestro contract](maestro-contract.md).

## Orca: durable mailbox, two different attention paths

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

## Paseo: daemon-owned provider sessions, including Copilot over ACP

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

## Herdr: identity reporting is not its message delivery channel

At `28360107c1bfab57fb0de99d74bfa48e74423ca8`, Herdr's Copilot hook reports native
session identity to Herdr ([hook][herdr-hook]). Cross-agent prompt delivery uses
the recipient terminal: text, delay, then Enter. Copilot also receives a
synthetic focus-gained terminal event ([prompt path][herdr-prompt],
[Copilot handling][herdr-focus]). That is input injection even without activating
an operating-system window.

Ordered terminal writes do not establish safe coexistence with a human's unsent
draft. Status waiting and terminal readback are also not exact request/reply
correlation ([wait contract][herdr-wait]). Identity observation is distinct from model-context delivery.

## Upstream CMUX: background transport is not a draft-safe mailbox

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

[cmux-actions]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarAction.swift#L10-L26
[cmux-binding]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Sources/TerminalController%2BControlTerminalBinding.swift#L7-L50
[cmux-host]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CmuxSidebarHost.swift#L84-L90
[cmux-mobile]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Sources/TerminalController%2BMobileChat.swift#L261-L336
[cmux-replay]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface%2BInput.swift#L869-L963
[cmux-send]: https://github.com/manaflow-ai/cmux/blob/aa4cc90348b96c2d087e6c5e9dee4b6756891bc4/Sources/TerminalController%2BControlSurfaceContext3.swift#L260-L366
[herdr-focus]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/app/api/agents.rs#L650-L687
[herdr-hook]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/integration/assets/copilot/herdr-agent-state.sh#L53-L92
[herdr-prompt]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/app/api/agents.rs#L111-L215
[herdr-wait]: https://github.com/herdrdev/herdr/blob/28360107c1bfab57fb0de99d74bfa48e74423ca8/src/app/api/agents.rs#L218-L257
[orca-contract]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/skill-guides/orchestration/references/messaging-and-gates.md#L6-L8
[orca-notify]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/mailbox-notification-coordinator.ts#L48-L75
[orca-router]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/structured-agent-session-runtime.ts#L288-L298
[orca-stage]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/mailbox-pointer-stage.ts#L97-L109
[orca-structured]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/structured-mailbox-pointer-delivery.ts#L215-L252
[orca-submit]: https://github.com/stablyai/orca/blob/33ba1ff3df247652c546985201d9a6f4edaec80b/src/main/runtime/orchestration/mailbox-pointer-submit.ts#L102-L128
[paseo-copilot]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/providers/copilot-acp-agent.ts#L81-L96
[paseo-send]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/agent-prompt.ts#L306-L338
[paseo-spawn]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/providers/acp-agent.ts#L2700-L2763
[paseo-steer]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/agent-manager.ts#L2635-L2775
[paseo-watcher]: https://github.com/getpaseo/paseo/blob/2c8e8a826810337492cc5a38bb0bbd705b6fb632/packages/server/src/server/agent/agent-prompt.ts#L428-L574
