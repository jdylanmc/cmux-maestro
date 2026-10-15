# Joe delivery and merge policy

Applies to the [selected #57 scope](issue-tracker.md) and its bootstrap PR.
This policy records settled delivery choices; it grants neither new product
scope nor unattended merge authority.

## Placement and capacity

- Use the current **human-authorized concurrency budget**, not an older fixed
  four/six-developer quota from another activation or adapter. Bootstrap and
  startup repair each consume a slot while active. Include useful support and
  retained resources within the verified runtime limits; reserve review capacity.
  Check live-workspace room, workspace stored-node/depth bounds and distinct host safety bounds before
  dispatch. A configurable product ceiling does not increase human authority or
  prove that retained history leaves free nodes.
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

Use [Joe pace](../../.agents/skills/joe-mode/DELIVERY-PACE.md) and the canonical
[PR states](../../.agents/skills/ship/DELIVERY.md#pr-states). Non-draft is not merge authority.

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
   head against current `main`**, shown by a green `ci-gate` check for that run. Record both SHAs and check results. If either
   changes, reconcile the candidate and refresh affected review plus complete
   CI evidence; stale success is insufficient.
5. Immediately before merging, re-read provider branch/ruleset protections,
   required checks, reviews, mergeability, and human authorization. Use an
   allowed merge method with `gh pr merge --match-head-commit <reviewed-head>`
   and explicit `--repo jdylanmc/cmux-maestro`; never use `--admin`, bypass
   checks, or queue an unguarded automatic merge. A changed head/base or blocked
   provider policy returns the candidate for reconciliation.

## Actual CI and formatting gates

`.github/workflows/ci.yml` is authoritative.

**When it runs (#192):**

- CI runs once for every pull request update (opened, synchronized or reopened), against GitHub's synthetic merge of the candidate with the base as it was at that update. A push run for a different tree never substitutes for it. If `main` moves afterwards, that PR run is stale too; refresh the candidate as item 4 above requires before treating it as merge evidence.
- Fork pull requests run the same suite with GitHub's read-only fork token; no step needs secrets.
- CI runs the full validation for pushes to `main`.
- A feature-branch push without a PR runs nothing. To validate one, open a draft pull request.
- Tags are not validated; the project pushes none today.

**Final coverage gate (#197):**

- The check named `ci-gate` is the merge signal, not the individual jobs. It needs every validation job, uses `if: always()`, and so runs for every validated pull request update and `main` push, even after a job fails or the run is cancelled. Steps default to `if: success()`, which a cancelled run would skip, so every gate step uses `if: always()`: the per-suite table still prints and the gate fails on the cancelled suite.
- It passes only when every required suite in `scripts/ci-required-suites.json` reports exactly `success`. Failure, cancellation, a missing job or result, contract drift, and any skip block it. That includes a job GitHub skipped because a job it needs failed: a skipped job can look green in a roll-up, but not to the gate.
- No suite may be "not applicable" yet. Selective suites (#194) must add a complete, successful classification to the evaluator, contract and tests together; until then any classification record fails the gate.
- Split or parallel jobs (#191, #196) join by adding the job to the gate's `needs` and to the contract. `scripts/test-build-metadata.py` fails if any job is missing from either. Its workflow guard reads job ids line by line, fails closed on any job it cannot parse (a quoted id, a trailing comment, a flow mapping or another key under `jobs:`), and cross-checks the ids against a real YAML parse. Write job ids as plain `name:` lines. Jobs may only use `runs-on`, `steps` and `permissions` (the gate also `needs` and `if: always()`); the only step condition is `if: always()`, and `timeout-minutes` is not allowed anywhere (#190: no arbitrary timeout cuts or blanket skips). Changing that allow-list is a merge-policy change.
- The gate judges job results, not the evidence inside them. Each job enforces its own: required artifacts upload with `if-no-files-found: error`, and the integrated harness enforces nonzero test execution, coverage accounting and candidate/base attribution. Losing that evidence fails the job, and so the gate.
- It runs on `ubuntu-latest`: evaluation is pure Python over job results and needs no macOS behaviour, so it does not wait for a macOS runner. It runs its own tests (`python3 scripts/test-ci-gate.py`) on that runner first.
- To verify: open the run for the exact candidate head, confirm `ci-gate` succeeded, and read its "Evaluate required suites" log or the run summary. The per-suite table must list every required suite as `PASS`. A missing `ci-gate` check is not a pass.
- On a pull request the gate checks out the candidate, so it runs the candidate's own `scripts/ci-gate.py`, `scripts/ci-required-suites.json` and `.github/workflows/ci.yml`. A candidate can therefore change what its own gate requires. Reviewers treat any change to those files as changes to merge policy, and check them against `scripts/test-ci-gate.py` and the guards in `scripts/test-build-metadata.py`.
- Branch protection on `main` is currently off (`gh api repos/jdylanmc/cmux-maestro/branches/main/protection` returns 404, and the repository has no rulesets), so the gate is advisory: GitHub does not block a merge on it. Requiring it is a separate human decision. Re-read protections before relying on them; a displayed check is not an enforced rule.

Its current commands, in order:

```sh
node --test scripts/test-skill-overrides.mjs
node scripts/check-skill-overrides.mjs
python3 scripts/test-joe-role-appearance.py
python3 scripts/test-cmux-maestro-orchestrator.py
python3 scripts/test-pet-kit.py
python3 scripts/test-beats.py
python3 scripts/test-delivery-proof.py
node --test scripts/test-delivery-proof.mjs
python3 scripts/test-build-metadata.py
python3 scripts/test-local-preview.py
./scripts/test-copilot-shell-reducer.sh
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
publish their candidate. This does not waive the complete pre-merge CI gate.
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
