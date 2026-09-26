# Issue tracker

- Provider: GitHub Issues, host `github.com`, repository `jdylanmc/cmux-maestro`.
- Use `gh` with explicit `--repo jdylanmc/cmux-maestro` for issue/PR commands.
  A remote identifies a repository, not authority over other repositories.
- Resolve authenticated identity with
  `gh api --hostname github.com user --jq .login`; Git author identity is not
  authentication.
- **PRs as a request surface: no.** Linked PRs remain delivery evidence, not a
  separate triage queue.

## Default backlog

The default backlog is **all open GitHub Issues in `jdylanmc/cmux-maestro`**.
Do not apply an assigned-to-me filter implicitly. An explicit issue or epic
request narrows this selection; do not silently broaden it to other issues,
repositories, or the organization.

Use complete pagination. GitHub's Issues API also returns pull requests, so
exclude those records rather than treating them as backlog items:

```sh
gh api --hostname github.com --paginate \
  'repos/jdylanmc/cmux-maestro/issues?state=open&per_page=100' \
  --jq '.[] | select(.pull_request == null) | {number, title, state, labels: [.labels[].name], assignees: [.assignees[].login]}'
```

The backlog is a request surface, not an instruction to execute every issue.
For authorized execution, select open issues carrying the mapped
[`ready-for-agent`](triage-labels.md) label, within the current requested scope,
then check dependencies, ownership and unresolved human decisions. Read each
selected issue, comments, labels, dependency relations and linked PRs before
dispatch. Never treat the CLI's default result limit as a complete backlog.

An active controller retains its explicitly assigned issue or epic scope;
changing this default does not expand an in-flight assignment or activate
Joe-mode. Reconcile an existing owner's scope before starting separate work.

The [visual reference and design-suite audit](../design/2026-09-25/README.md)
remain evidence for that feature area, not a repository-wide backlog filter.

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
