# Triage labels

The provider representation is **GitHub issue labels** in
`jdylanmc/cmux-maestro`. The approved vocabulary is:

| Canonical role | GitHub label | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Awaiting maintainer evaluation |
| `needs-info` | `needs-info` | Missing information from the reporter |
| `ready-for-agent` | `ready-for-agent` | Fully specified work suitable for an AFK agent |
| `ready-for-human` | `ready-for-human` | Requires human implementation |
| `wontfix` | `wontfix` | Work will not be pursued |

The Project Manager initialized missing labels with human approval, preserving
existing definitions. Reuse them; do not recreate labels or overwrite their
colors/descriptions as a setup side effect.

Joe selects eligible work using `ready-for-agent` within the
[selected backlog](issue-tracker.md), subject to dependencies and ownership.
Unresolved human-owned scope decisions prevent readiness. Label edits require
scoped authorization, preserve unrelated labels, and do not implicitly close
or reopen issues.
