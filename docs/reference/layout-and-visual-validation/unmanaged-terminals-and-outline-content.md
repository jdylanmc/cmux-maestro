# Unmanaged terminals and outline content

[↑ Taskboard, layout, and visual validation](../layout-and-visual-validation.md) | [← Details inspector and row state](details-inspector-and-row-state.md) | [Outline grouping and density →](outline-grouping-and-density.md)

For unmanaged terminals with exactly one observed session, state and children
show on the named terminal row. No duplicate provider/ID
heading. Multiple sessions stay individually inspectable; none is guessed as
current owner. Passive skill/shell history moves to selected session's
**Other activity** disclosure. Taskboard does not list it. Agents, structural
ancestors, active/blocked/failed work and outstanding attention stay in outline.
Exception: ordinary running shell invocations. Verified, unambiguous leaf
commands fold into quiet metadata line of exact owning session or
agent, such as "Running a command". Concurrent commands are counted. Blocked,
attention-bearing, unresolved and structural running shell rows stay visible.
Accepted shell invocation completions, successful or failed, leave the sidebar
child projection, not merely the outline. They create no failure attention or
manual dismissal burden, and do not appear in **Other activity**. Reader snapshots
retain bounded terminal outcomes and lifecycle/replay evidence; agent failures and independent requests stay
protected (ADR 0010).
Incomplete-history context and collapsed-branch counts stay with owning
row, not on standalone diagnostic rows. Managed rows offer disclosure and a
collapsed work summary only for visible child content; incomplete counts alone
do not make an empty branch expandable. Incomplete internal-task counts still
prevent failed-worker dismissal, independently of disclosure. Chevron needs no "Branch collapsed"
caption. Registration is neutral, not a claim that an agent runs. Stale
managed evidence and unconfirmed/ended process ownership cannot show a live state.
