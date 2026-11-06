# Hover previews and copy

Part of [sidebar presentation](../sidebar-presentation.md). Previous page is [Agent icons](agent-icons.md). Next page is [Hover components and detail labels](hover-components.md).

Only the workspace **name text** triggers its passive hover preview. Disclosure,
blank title fill, and actions do not. Leaving that text cancels or dismisses the
workspace hover immediately. Agent previews keep a 300 ms crossing grace.
Shared native card prefers the right edge, fits the available screen, and
scrolls long metadata. Hover waits 350 ms. Keyboard focus on a title previews it
without pressing it. **Tab** enters its preview controls, then continues past the
originating title after the last control. **Escape** or **Shift-Tab** returns to
that title. Next **Tab** continues onward, not back into the preview.
Explicit previews also close on outside
interaction. Workspace previews
show only current granted workspace metadata and shared-surface counts. Label denied
or ambiguous evidence unavailable. **Ports (CMUX, workspace-wide)** lists the port numbers
CMUX's `networkPorts` scope reports for the whole workspace, sorted and copyable, or
`None reported` (not proof that nothing listens) or `Not granted`. CMUX gives no owner,
address, protocol or completeness, so agent previews never show it.
Managed agent previews add one wrapping **Processes** field:
`PID 4242 (python3.12); PID 4243 (node)`, capped at 8 entries with trailing `+N`
overflow. Copy gives visible current PIDs, one per line, only for a complete,
current observation. Helpers stay counted separately; listeners keep their
endpoint rows ([background processes and ports](../processes-and-ports.md)).

Hover, details, footer and row tooltips use labels and terse values rather than
explanatory prose. **Observation: Stale/Unavailable**, **Owner: Unconfirmed** and
**Child history: Incomplete** retain uncertainty visibly; no collection, retention,
acknowledgement or permission behavior changes. Child placement is **Parent session**.
Directory hints retain **Source**, **Report time: Unknown** and the unverified
agent/tool or child-directory distinction. Observation summaries and warnings use
the same compact statuses wherever shared. Omitted lower bounds remain `N+` with
unknown totals. **Turn scope: Main turn only** never claims background completion.
The inline session row, session details and aggregate omission count reuse one
formatter for `N+ · Total: Unknown`. Exact counts remain `N`.
The inline caption adds **Omitted tasks:** and **Active: Unknown** for uncounted
work, or **Omitted working/blocked: N** for a known active count.
An old managed node retains **Observation: Stale** in its state cue, hover and row
tooltip even inside a fresh snapshot. Workspace attention tooltips use counted
labels, keeping **Input reason: Unreported** and **Live state: Unverified** explicit.
