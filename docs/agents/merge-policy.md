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
4. Require a green `ci-gate` check for the **exact candidate head against current
   `main`**: every applicable suite passed, or `ci-gate` shows it `NOT APPLICABLE`
   from that run's `ci-classify`. The classification record's `base` must equal
   current `main` and its `head` must equal the candidate. A selection computed
   against a stacked parent branch, or a stale base, is not merge evidence.
   Record both SHAs and check results. If either changes, reconcile the candidate
   and refresh affected review plus complete CI evidence; stale success is
   insufficient.
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

- The check named `ci-gate` is the merge signal, not the individual jobs. It needs the classifier and every validation job, uses `if: always()`, and so runs for every validated pull request update and `main` push, even after a job fails or the run is cancelled. Steps default to `if: success()`, which a cancelled run would skip, so every gate step uses `if: always()`: the per-suite table still prints and the gate fails on the cancelled suite.
- It passes only when the classifier (`classifier_job` in `scripts/ci-required-suites.json`) succeeded with a valid record for this run, and every required suite in that contract either reports exactly `success` or was skipped as not applicable (see Suite selection below). Failure, cancellation, a missing job or result, contract drift, and any other skip block it. That includes a job GitHub skipped because a job it needs failed, or because the classifier failed: a skipped job can look green in a roll-up, but not to the gate.
- Split or parallel jobs (#191, #196) join by adding the job to the gate's `needs` and to the contract. `scripts/test-build-metadata.py` fails if any job is missing from either. Its workflow guard reads job ids line by line, fails closed on any job it cannot parse (a quoted id, a trailing comment, a flow mapping or another key under `jobs:`), and cross-checks the ids against a real YAML parse. Write job ids as plain `name:` lines. Jobs may only use `runs-on`, `steps` and `permissions`. The gate also has `needs` and `if: always()`; the classifier also has `outputs`; each validation job also has exactly `needs: [ci-classify]` and its own selection condition, `if: needs.ci-classify.outputs.run_<job> != 'false'` (with `-` written `_`), and nothing else. The only step condition is `if: always()`, and `timeout-minutes` is not allowed anywhere (#190: no arbitrary timeout cuts or blanket skips). Changing that allow-list is a merge-policy change.
- The gate judges job results, not the evidence inside them. Each job enforces its own: required artifacts upload with `if-no-files-found: error`, and the integrated harness enforces nonzero test execution, coverage accounting and candidate/base attribution. Losing that evidence fails the job, and so the gate.
- It runs on `ubuntu-latest`: evaluation is pure Python over job results and needs no macOS behaviour, so it does not wait for a macOS runner. It runs its own tests (`python3 scripts/test-ci-gate.py`) and the classifier's (`python3 scripts/test-ci-classify.py`) on that runner first, so a broken evaluator or classifier fails the gate.
- To verify: open the run for the exact candidate head, confirm `ci-gate` succeeded, and read its "Evaluate required suites" log or the run summary. The table lists `ci-classify` as `PASS`, then every required suite as `PASS` or `NOT APPLICABLE`, with the classifier's selection reason. A missing `ci-gate` check is not a pass.
- On a pull request the gate checks out the candidate, so it runs the candidate's own `scripts/ci-gate.py`, `scripts/ci-required-suites.json` and `.github/workflows/ci.yml`; the classifier likewise runs the candidate's `scripts/ci-classify.py` and `scripts/ci-suite-map.json`. A candidate can therefore change what its own gate requires. Reviewers treat any change to those files as changes to merge policy, and check them against `scripts/test-ci-gate.py`, `scripts/test-ci-classify.py` and the guards in `scripts/test-build-metadata.py`.
- Branch protection on `main` is currently off (`gh api repos/jdylanmc/cmux-maestro/branches/main/protection` returns 404, and the repository has no rulesets), so the gate is advisory: GitHub does not block a merge on it. Requiring it is a separate human decision. Re-read protections before relying on them; a displayed check is not an enforced rule.

**Suite selection (#194):**

- `ci-classify` (on `ubuntu-latest`, before any validation job) classifies the change set of the exact pull request run and decides, for each required suite, whether it applies. It reads the base and head SHAs from the pull request event through environment variables, verifies that the checkout is GitHub's synthetic merge of exactly that base and head, and classifies every path that differs between the base and that merge, plus every path the head changed since its merge base, so a change `main` already contains still counts. Renames count as a deletion and an addition, so both paths are classified.
- `scripts/ci-classify.py` applies the reviewed map `scripts/ci-suite-map.json`: ordered path-glob rules, the first match wins. A file no rule matches is unmapped and selects every suite. Only these rules select fewer than every suite:
  - Markdown documentation (`docs/**/*.md`, `README.md`, `CHANGELOG.md`, `CONTEXT.md`, `AGENTS.md`) and anything else under `docs/` select only `validate-contracts`: `node scripts/check-skill-overrides.mjs` checks policy links in every tracked Markdown file, and `scripts/test-build-metadata.py` reads this policy. No Xcode resource, build phase, `test.sh` input or guide probe input reads them.
  - Images under `docs/` (`docs/**/*.png`) select no suite.
  - Leaf contract tests that only `validate-contracts` runs (`scripts/test-beats.py`, `test-pet-kit.py`, `test-joe-role-appearance.py`, `test-skill-overrides.mjs`, `test-local-preview.py`, `test-cmux-maestro-orchestrator.py`, `test-delivery-proof.py`, `test-delivery-proof.mjs`) select only `validate-contracts`.
- Everything else selects every suite, including bundled skills (`skills/`, `.agents/skills/`), `skills/maestro/SKILL.md` (the guide's build fingerprint), bundled and shared scripts and fixtures, resources, and native, orchestration, messaging and guide code. The workflow and the selection and gate files (`.github/workflows/**`, `scripts/ci-classify.py`, `scripts/ci-suite-map.json`, `scripts/test-ci-classify.py`, `scripts/ci-gate.py`, `scripts/ci-required-suites.json`, `scripts/test-ci-gate.py`) always select every suite; the classifier enforces that even if the map is edited. Mixed changes select the union.
- Any doubt selects every suite, never an empty success: pushes to `main` (the classifier never reads git for them, and the gate rejects a push record that marks any suite not applicable), an unsupported event, a missing or malformed base, head or run SHA, a checkout that is not that exact merge, a git error, an empty change set, or an invalid map. If the classifier job itself fails or is cancelled, every validation job is skipped and the gate fails; that is an explicit failure, not a selection.
- It publishes a JSON record (job output `classification`) and one `run_<job>` flag per suite. The step summary "Suite selection" lists each suite as selected or not applicable with its reason, and each changed file with the rule that matched it. A validation job is skipped only when its flag is `false` (case-insensitively, because GitHub compares expression strings that way); a missing or garbled flag runs it, and the gate rejects any flag other than the literal `false`.
- "Not applicable" means the classifier decided, for this run, that no changed file can affect that suite. It is a gate verdict (`NOT APPLICABLE`), distinct from a skip: the gate accepts a skipped suite only when `ci-classify` succeeded and its record is complete, from the same run (run id, event and commit), decides exactly the required suites, agrees with the published flags, and marks that suite not applicable with a reason. Any other skip, and any malformed, partial or mismatched record, fails the gate. An applicable suite that fails still blocks it.
- `main` always runs everything. A later full run on `main` is not a substitute for applicable PR coverage, and a not-applicable suite on a PR is not evidence that the suite passes.
- Trade-off: every validation job now waits for `ci-classify` (a full-history checkout on Linux) before it is queued. Reviewers treat changes to the map, the classifier or their tests as changes to merge policy. A new rule must prove its dependency edges (bundling, build phases, test inputs, the guide probe's source inventory) and add a test; when in doubt, leave the path unmapped.

**Early failures (#196):**

- Validation runs as two independent macOS jobs with no `needs` between them (each needs only `ci-classify`), so a failure in one never skips the other's suites. Each is its own check and reports as soon as it finishes; `ci-gate` still requires both, plus `guide-ui-consumer-probe`.
- `validate-native` runs only the integrated Swift tests (`./scripts/test.sh`), immediately after checkout, then uploads their evidence. They fetch the SDK and compile in their own derived data, and need nothing else. Before the split they waited behind the orchestrator, preview-transaction and other suites: runner start to `test.sh` start was 11m58s in run 38662873916, 15m50s in run 37978471696 and 17m01s in run 38671818542. With the split, run 38676895215 started `test.sh` 11s after the workflow was created.
- `validate-contracts` runs everything else, short suites first, including the standalone native checks (hooks, sandbox, unsigned build, setup). It ends with the long preview-transaction and orchestrator suites, then uploads the setup evidence.
- Each artifact uploads from the job that produces it, after its producer: `integrated-test-scope-evidence` and `sidebar-layout-offscreen` after `./scripts/test.sh`, and `copilot-setup-evidence` (the metadata watchdog controls and any metadata stall diagnostics) after `./scripts/test-copilot-setup.sh`.
- Within a job a failing step still skips its later steps, as before; the always-run uploads keep failure evidence. If a step before setup fails, the setup upload also reports that its files are missing. The integrated harness's selector restrictions, isolated regression, guide acceptance and full-complement accounting are unchanged.
- Trade-off: the split adds a third macOS job, which can queue separately when runners are scarce. #191 measures concurrency and owns runner placement.

Its current commands, in order, per job. Each runs at most once; a not-applicable suite runs none of its commands; `scripts/test-build-metadata.py` checks these lists against the workflow.

`validate-native` (integrated Swift tests):

```sh
./scripts/test.sh
```

`validate-contracts` (script, contract and standalone native suites):

```sh
node --test scripts/test-skill-overrides.mjs
node scripts/check-skill-overrides.mjs
python3 scripts/test-joe-role-appearance.py
python3 scripts/test-pet-kit.py
python3 scripts/test-beats.py
python3 scripts/test-delivery-proof.py
node --test scripts/test-delivery-proof.mjs
python3 scripts/test-build-metadata.py
./scripts/test-copilot-shell-reducer.sh
./scripts/test-fetch-sdk-concurrency.sh
./scripts/test-copilot-hook.sh
./scripts/test-copilot-sandbox.sh
./scripts/build-unsigned.sh
./scripts/test-copilot-setup.sh
python3 scripts/test-local-preview.py
python3 scripts/test-cmux-maestro-orchestrator.py
```

CI also requires the synthetic sidebar layout render artifact
`sidebar-layout-offscreen` from `.build/layout-validation/offscreen/*.png`,
uploaded by `validate-native`.
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
