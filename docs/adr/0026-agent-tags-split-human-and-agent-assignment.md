# Agent tags keep human and agent assignment in separate stores

A session's tags come from two sources: the human in the sidebar and the agent itself. The human's tags and every tag color live in the sidebar's own container (`sidebar-tags.json`). An agent's own tags live in `Copilot/tags/agent-tags.json`, written only by the controller's `tags --self` command after the native identity helper proves the caller owns that exact session. The sidebar reads that file through its existing read-only Copilot grant. Both are keyed by exact session UUID and use one canonical slug rule. Contract: [agent tags](../reference/agent-tags.md).

Why: authority follows storage. The agent path has no way to write the human's tags or any color, and the sidebar has no way to write an agent's tags. Removing one source can't remove the other's assignment. No new entitlement is needed: the only writable grant outside the container stays the Beats store (ADR 0020).

Rejected: one shared store under a new writable grant (widens the sandbox, ADR 0001); putting tags in the Beats store (that grant is for Beats); agent tags in the per-session appearance record (that file belongs to the hook's appearance contract and would couple tags to icon and pet changes); per-agent colors.

Consequence: any same-user process can edit either file; readers check shape, owner and privacy only. Limits (6 per source, 24 characters) refuse rather than truncate. A changed canonical rule needs a new version and a migration of both stores.
