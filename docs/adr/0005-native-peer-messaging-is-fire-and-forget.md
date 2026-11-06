# Native peer messaging is fire-and-forget

Same-workspace sessions that have the global `/maestro` guide message each other through Copilot's native `session.send` with `mode: "enqueue"`. Messages are independent of focus, grant no lifecycle or process control, and use no terminal keystrokes. Copilot owns scheduling: Maestro adds no busy scheduler, receipts, retries, or completion tracker.

Why: typing into a terminal clobbers the human's draft. Copilot already queues prompts.

Rejected: terminal input fallback, acknowledgement and retry layers, a standalone broker.

Consequence: no delivery proof. Same-user processes are trusted. Routes are generation-bound and retired on provider exit.

## Evidence: what the upstream systems do

From [`docs/native-messaging/upstream-systems.md`](../native-messaging/upstream-systems.md). Pinned source research that informed this decision, moved here verbatim. Comparisons are pinned source evidence, not tests of those products' installed behavior.

### Orca: durable mailbox, two different attention paths

At `33ba1ff3df247652c546985201d9a6f4edaec80b`, Orca persists mail, then sends
the recipient a pointer to check it. The body arrives in the later CLI/tool
result. The terminal path writes into a pseudoterminal (PTY) and submits Enter
separately. The structured path journals a user message and dispatches it
through an Orca-owned provider session. These transports are not interchangeable.
See [staging][orca-stage], [submission][orca-submit], [structured delivery][orca-structured], [notification][orca-notify].

The structured router covers Claude and Codex, not Copilot ([router][orca-router]),
so Orca shows no injection-free delivery into an existing Copilot terminal. Its
durable mailbox and separate acknowledgements are contrasts Maestro need not
copy. Orca itself separates durable enqueue from attention, reading and
completion ([delivery contract][orca-contract]).

### Paseo: daemon-owned provider sessions, including Copilot over ACP

At `2c8e8a826810337492cc5a38bb0bbd705b6fb632`, Paseo's daemon owns agent
runtimes. An agent tool dispatches a prompt, and a daemon watcher can notify the
caller through provider input, not a UI notification or Model Context Protocol
server push ([watcher][paseo-watcher]).

Copilot runs as `copilot --acp`: Agent Client Protocol (ACP) over piped
stdin/stdout ([adapter][paseo-copilot], [process launch][paseo-spawn]). That is
focus-independent orchestration of daemon-managed sessions, not attachment to
human-operated native terminals. Ordinary dispatch can replace active work, and
steering has fallbacks ([send][paseo-send], [steering][paseo-steer]). Maestro
imports none of this.

### Herdr: identity reporting is not its message delivery channel

At `28360107c1bfab57fb0de99d74bfa48e74423ca8`, Herdr's Copilot hook reports
native session identity to Herdr ([hook][herdr-hook]). Prompts between agents
go through the recipient terminal as text, a delay and Enter, plus a synthetic
focus-gained event for Copilot ([prompt path][herdr-prompt],
[Copilot handling][herdr-focus]). That is input injection, even with no
operating-system window activated.

Ordered terminal writes do not make a human's unsent draft safe, and status
waits plus terminal readback are not exact request/reply correlation
([wait contract][herdr-wait]). Identity observation is not model-context
delivery.

### Upstream CMUX: background transport is not a draft-safe mailbox

At `aa4cc90348b96c2d087e6c5e9dee4b6756891bc4`, CMUX offers explicit terminal
targets, improved runtime binding and background text/key delivery
([binding][cmux-binding], [send implementation][cmux-send]). The sidebar SDK
has no terminal-input messaging action ([actions][cmux-actions], [host][cmux-host]).

The terminal-injection investigation found no atomic send-if-unfocused
operation in the inspected interfaces. Separate focus check and send would race,
buffered input loses a provider's draft, and the mobile-chat path explicitly
clears input ([input replay][cmux-replay], [mobile chat][cmux-mobile]). Those
findings still hold for injection, but **the proposed focus-gate host patch is
no longer needed for this feature**: Maestro delivers through Copilot's native
conversation API, not CMUX input. No host fork, foreground gate or sidebar
rewrite follows.

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
