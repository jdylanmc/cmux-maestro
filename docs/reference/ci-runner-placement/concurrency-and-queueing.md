# Concurrency and queueing

[↑ CI runner placement](../ci-runner-placement.md)

CI now cancels superseded pull request runs using a workflow-level group keyed
by workflow name and PR number. Different PRs do not cancel one another.
Pushes use the ref instead, with in-progress cancellation disabled for `main`;
GitHub can still replace a pending run in the same group. Cancellation frees
obsolete work, not a guarantee that a runner stops immediately. The replacement
head still needs its own green `ci-gate`. Cancelled work never counts as passing.

Suite selection is unchanged: ordinary `docs/**`, `README.md` and
`CHANGELOG.md` changes need no macOS runner; the merge-policy document still
selects contracts. `skills/**` and `.agents/skills/**` intentionally select all
suites because bundled skills and the guide fingerprint are build/test inputs.
They are not documentation-only changes under the reviewed #194 map.

macOS concurrency is limited per account, not per repository, and `pr-sniper` shares it. The measured concurrency and queue tables are [archived](../../evidence/ci.md#concurrency-and-queueing).
