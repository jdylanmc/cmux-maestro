# State cues and headers

Part of [sidebar presentation](../sidebar-presentation.md). Previous page is [Footer and session previews](footer.md). Next page is [Workspace summaries and header actions](workspace-summaries.md).

Working agents use one 9-point open ring, rotating linearly once per second.
Reduce Motion keeps the ring static. Questions and approval requests use a
distinct static exclamation mark. Working rows have no shimmer or moving wash.
Blocked rows keep a subtle static red background. Idle/unknown rows do not
pulse or glow. State cues belong to their exact row, never its descendants.
The selected workspace's uniquely focused surface has a glowing left border,
separate from activity and icon color. Other workspaces' remembered focus does
not light a border. Ambiguous/unavailable focus evidence does not guess.
Identity colors do not change this treatment. Icons have no wand decoration.
Choosing an icon or role preset does not imply orchestration ownership.
Interactive agent rows (managed agents and single-session Copilot surfaces) are one
line: icon, name, tag chips (#51), state cue. No subtitle, location or activity
caption: 30-point Compact, 34-point Comfortable rows (ADR 0028). Their state, assigned
directory and activity stay in the row's help, and the assigned directory also appears in hover and details. Other
surfaces keep a single-line name and one quiet metadata line: 11/9-point
type in 46-point Compact rows, 12/10-point type in 52-point Comfortable rows.
Missing context adds no placeholder or separator. Ordinary Terminal/Browser
labels, full location help and keyboard-accessible agent previews stay unchanged.
Routine Unknown, State unavailable and Last verified prose moves to full help,
accessibility and details, not a third row. Unknown/stale states keep a static
dashed cue, never an idle or working claim. Incomplete child-history context
shares that row's exact state cue instead of a redundant trailing info icon.
Protected attention and actual errors stay visible. Coordinator
activity comes only from a fresh, unique, live Copilot observation on its exact
workspace/surface. Registration or child activity alone cannot start a pulse.
**Sidebar settings → Terminal icon** offers Ghost and plain `>_` styles.
