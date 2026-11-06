# Footer and session previews

[↑ Sidebar presentation](../sidebar-presentation.md) | [← Hover components and detail labels](hover-components.md) | [State cues and headers →](state-cues.md)

Flush footer uses native adaptive colors. It shows the verified agent's animated
Codex-format pet (bundled original Maestro robot head by default, see
[Pets](../pets-and-icons/pets-cmux-maestro-native-maestro-pet.md)). Click it to open the pet picker. Ordinary
terminals and browsers show no pet. Metadata is bounded and scrollable. Verified
Git counts use the existing compact badge. Full paths stay in Details. Existing
session-ID copy control stays near identity. No context percentages, elapsed
durations, tags or lifecycle controls are added.
Steady connection success adds no label or row, leaving the footer lower while
preserving the host's 50-point clearance. Waiting, disconnection and navigation
errors or permission summaries stay visible.

Same preview is available on managed agent and observed session titles in
Hierarchy and Taskboard, and on non-task activity titles in Hierarchy. Internal tasks instead use passive
single-line names with complete accessibility labels and tooltips, not chat
navigation or identity previews. Each card resolves its own exact
subject and only current or explicitly last-known metadata. Label missing/expired
observations. Never replace them with invented model, context, timing or
Git metrics. Windowless children keep parent-session placement context.
**Workspace path** belongs to the workspace preview and Details. Agent previews
and the agent footer omit it, keeping **Project path** and **Surface directory**.
Agent cards show that exact session's own pet, honoring its hidden state; child,
terminal, browser and workspace cards show none. Hovering never changes the
footer pet. Opening a card never invokes the existing inspection/mark-seen action. Icon
picker, title-to-focus action, and history controls keep their explicit semantics.

Agent previews put a **Copy session ID** button beside the exact session GUID.
Observed children label their inherited identity **Parent session ID** and copy
that parent GUID, never the child/worker/run/surface ID. Missing, ambiguous, or
unavailable session identity has no copy action. Open **Preview** for keyboard
access. Hovering, opening, and refreshing never write to the clipboard.
A stale managed observation still offers its exact recorded session ID with
the existing last-known notice. Copying does not imply the session is live.
Every labelled detail (session ID, model, observed time, child history, paths) has a small
copy icon beside its label, always visible and dimmed until hovered or focused, in the pinned
footer and the preview. Successful copy swaps the icon for a checkmark and announces
**Copied** to VoiceOver, with no visible text. Failure shows **Could not copy. Try again.**
Changing the GUID clears feedback.
Small `SidebarCopyableValue` control receives an injected action. It knows
nothing about session lookup, persistence, host navigation, or the pasteboard.
