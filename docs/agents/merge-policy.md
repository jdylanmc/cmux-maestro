# Joe delivery and merge policy

Applies to the [selected #57 scope](issue-tracker.md) and its bootstrap PR.
This policy records settled delivery choices; it grants neither new product
scope nor unattended merge authority.

## Placement and capacity

- The human-authorized pool is **four concurrent developers**. Bootstrap and
  startup repair each consume a slot while active; do not exceed the pool.
- Each independent writer owns a standalone Git worktree and delivery branch.
  The Project Manager coordinates on `main`, Discovery uses `discovery/<feat>`,
  and the separate merge coordinator uses `pr-sniper`. Never repurpose another
  owner's checkout or run implementation edits on `main`.
- Use the dedicated installed `.agents/skills/cmux-maestro-orchestrate/`
  lifecycle and native `/maestro` messaging described by `skills/maestro/`.
  Do not replace them with generic hidden worker tabs, terminal keystrokes,
  timers, services, or a new messaging/claim framework. A tabless bootstrap
  helper is not a managed Maestro worker and must not claim native bindings.
- No global settings or live-session changes follow from this configuration.
  Preserve provider denies, descendant non-escalation, resource bounds, and
  exact session ownership.

## Review and user merge gate

1. The implementation author publishes a candidate and **never self-merges**.
   Only a separate, explicitly human-authorized **PR Sniper** may merge scoped
   PRs. AFK implementation/publication approval is not merge approval.
2. Require **one independent deep Roast per PR**. Preserve its reviewer,
   candidate head, base, findings, and evidence. Follow-ups are light
   verification of fixes and affected behavior, not repeated full deep reviews.
   Changes after review still require verification; carry evidence forward
   only when it remains applicable to the current candidate.
3. Before merge, PR Sniper checks issue coverage, intended visual alignment
   (or an evidenced not-applicable result for nonvisual work), and resolution
   of all findings. No missing evidence may be reported as a pass.
4. Require all repository CI commands below to pass for the **exact candidate
   head against current `main`**. Record both SHAs and check results. If either
   changes, reconcile the candidate and refresh affected review plus complete
   CI evidence; stale success is insufficient.
5. Immediately before merging, re-read provider branch/ruleset protections,
   required checks, reviews, mergeability, and human authorization. Use an
   allowed merge method with `gh pr merge --match-head-commit <reviewed-head>`
   and explicit `--repo jdylanmc/cmux-maestro`; never use `--admin`, bypass
   checks, or queue an unguarded automatic merge. A changed head/base or blocked
   provider policy returns the candidate for reconciliation.

## Actual CI and formatting gates

`.github/workflows/ci.yml` is authoritative. Its current commands, in order:

```sh
python3 scripts/test-cmux-maestro-orchestrator.py
python3 scripts/test-delivery-proof.py
node --test scripts/test-delivery-proof.mjs
python3 scripts/test-build-metadata.py
python3 scripts/test-local-preview.py
./scripts/test-fetch-sdk-concurrency.sh
./scripts/build-unsigned.sh
./scripts/test.sh
./scripts/test-copilot-setup.sh
./scripts/test-copilot-hook.sh
./scripts/test-copilot-sandbox.sh
```

CI also requires the synthetic sidebar layout render artifact
`sidebar-layout-offscreen` from `.build/layout-validation/offscreen/*.png`.
Visual delivery review uses applicable renders and acceptance evidence, not
merely a successful artifact upload.

The formatting gate is `git diff --check` on the actual candidate diff
(`git diff --check origin/main...HEAD` for a committed branch after refreshing
the remote base). **No dedicated linter currently exists**; do not invent a
lint command or report lint as passed.

Configuration-only authors may run the smallest relevant document/package
checks and formatting gate locally; no full native build is required just to
publish their draft. This does not waive the complete pre-merge CI gate.
`./scripts/build-register.sh` is a local installation action, not a CI command;
do not run it as an incidental configuration check.

## After a merge

The Project Manager advances its clean `main` checkout by guarded fast-forward
only, verifying expected local/remote commits and ownership. Never reset,
force-push, overwrite local changes, or move another worker's branch.
Installation verification or updates require a separate, current human grant;
they are never an automatic merge side effect. Installation is currently
explicitly deferred. Do not retry an unresolved installer guard or disturb
live sessions, and never use administrative bypass. Retain the last working
install and report blockers; independent work may continue.
