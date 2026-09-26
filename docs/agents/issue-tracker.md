# Issue tracker

- Provider: GitHub Issues, host `github.com`, repository `jdylanmc/cmux-maestro`.
- Use `gh` with explicit `--repo jdylanmc/cmux-maestro` for issue/PR commands.
  A remote identifies a repository, not authority over other repositories.
- Resolve authenticated identity with
  `gh api --hostname github.com user --jq .login`; Git author identity is not
  authentication.
- **PRs as a request surface: no.** Linked PRs remain delivery evidence, not a
  separate triage queue.

## Selected Joe backlog

The latest visual reference and full design-suite audit are
[locked separately](../design/2026-09-25/README.md). The September 25
design includes Beats and new follow-up work; auditing or publishing that
reference does not silently expand the active Joe dispatch selection below.

The approved visual delivery is parent [#57](https://github.com/jdylanmc/cmux-maestro/issues/57)
and these fourteen children:
**#39, #43, #44, #45, #46, #48, #49, #50, #51, #52, #55, #58, #59, #60**.
The default view is this **full selected scope**, never assigned-to-me or the
entire repository. Stage and Beats are deferred. New children or unrelated
work require scope reconciliation with the owning Project Manager; discovering
them does not automatically expand this selection.

Read each selected issue explicitly, including comments, labels, dependencies,
and linked PRs before dispatch:

```sh
gh issue view 57 --repo jdylanmc/cmux-maestro --comments
gh api --hostname github.com repos/jdylanmc/cmux-maestro/issues/57/sub_issues --paginate
```

Intersect live relations with the explicit selection above. Fetch complete
pages for list queries; never treat a CLI default limit as the full backlog.
Use GitHub's open/closed state plus the mapped
[`ready-for-agent`](triage-labels.md) label for eligible work. Readiness does not
override ownership, unresolved decisions, or unavailable dependencies.

Use native GitHub sub-issue and dependency relations when present. Preserve
existing task-list/`Part of #57` or `Blocked by: #N` references as evidence
where native relations are unavailable; do not silently migrate them.
An unmerged dependency is not present on a worker's base simply because its
checks pass.

## Ownership and writes

The Project Manager owns dispatch and reconciles live assignments/claims and
linked PRs before reserving work. Do not take another worker's issue, replace
assignees, or run parent and child implementation deliveries concurrently over
the same scope. No new automated claim mechanism is introduced here.

Tracker/label initialization was approved separately. These files do not grant
blanket issue creation, assignment, closing, or readiness updates. Mutations
require the calling workflow's scoped authorization, preserve unrelated labels,
and must be reconciled before retrying uncertain writes. Use non-closing issue
references for partial or configuration-only deliveries.
