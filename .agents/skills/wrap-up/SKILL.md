---
name: wrap-up
description: "Human-invoked checkpoint after ad-hoc work. Freeze new functionality, true-up with main, make every test and lint gate pass, reconcile documentation and the visual proof of concept with what changed, and deliver everything as one undrafted pull request with green CI."
disable-model-invocation: true
user-invocable: true
---

# Wrap-up

**Entry:** Human only. Turn a stretch of ad-hoc work into one reviewed-ready checkpoint: frozen scope, current with main, passing gates, truthful docs and visual proof of concept (POC), one undrafted pull request (PR) with green CI. The original [intent](intent.md) is preserved unchanged.

Wrap-up closes work; it does not extend it. The branch's current behavior is the specification. The only code changes allowed are those that make existing behavior pass its gates or make docs and the POC tell the truth.

## 1. Freeze and take inventory

- **Stop new functionality.** Do not start features, refactors, polish or "while I'm here" fixes. If something new is noticed, list it under *Deferred* in the PR; do not do it.
- Work on one branch/worktree. Confirm it is the human's ad-hoc branch, the working tree is understood, and nothing unrelated is staged. Read the repository's `AGENTS.md` for build, test, lint, commit-identity and PR rules; they outrank this skill.
- Build the inventory the rest of the skill uses: `git log --oneline <base>..HEAD`, `git diff --stat <base>...HEAD`, and a plain list of user-visible behavior changes, new/removed UI, new permissions or entitlements, new files shipped to users, and new commands or skills.

## 2. True-up with main

- Fetch and identify the default branch. Update it, then bring the branch current by the repository's convention (rebase for a private branch, otherwise merge). Resolve conflicts by preserving both intents; when intent is unclear, stop and ask.
- Re-run the inventory after the update; main may have changed behavior your docs or tests describe.

## 3. Make the gates pass

- **Discover gates from the source of truth, not memory:** the CI workflow files, `AGENTS.md`, and package scripts. The gate set is what CI will run. Run every gate locally in CI order, using the repository's own commands, long ones in the background.
- **Lint** means every linter, formatter, type check and static validator the repository defines. If none is defined for a language you touched, at minimum run the language's syntax check and `git diff --check`. Do not add new tooling or loosen rules.
- **Fix the cause.** A failing test is either a regression (fix the code) or an outdated expectation caused by an intended change (update the test, and say so in the PR). Never skip, disable, delete or weaken a test or gate to turn it green. Flaky or pre-existing failures: reproduce on the base branch before claiming that, and report them instead of hiding them.
- Add tests only for behavior this branch added that has none, and only where the gate set would otherwise leave it unprotected. Keep them small and in the existing style.
- Finish with one complete, clean pass of every gate on the final commit.

## 4. Reconcile documentation

Make every document that describes behavior match the branch, not the intent:

- README, changelog, guides, in-repo docs, help text and skill documentation. Search for removed names, old counts ("six shortcuts"), old paths and old limits, not only for new terms.
- Bundled skills and their installer lists, parity or coverage matrices, and architecture notes touched by new commands, permissions or files.
- **Frozen or approved historical records stay unchanged** (approved design captures, hashed archives, dated evidence). Reconcile through the current, living documents and say which historical records were intentionally left alone.
- Do not claim what was not verified. If a behavior was checked only by build or unit test and not on screen or on a live host, write that.

## 5. Reconcile the visual POC

- Find the repository's current runnable visual POC or reference prototype (not a frozen approved archive). Update it so its screens, states, labels, assets and behavior match the shipped UI changes: added, removed and re-styled elements, and new states.
- Keep it synthetic and self-contained; do not invent production behavior. Run its own verification scripts, and fix them where the intended change makes an assertion obsolete.
- If the repository has no current POC, say so; do not create one.
- If the POC is frozen by an approval record, do not edit it: add or update the working copy the repository designates, and note that the approval is unchanged.

## 6. Publish one pull request

- One PR contains everything: the work, any new skill or doc, test and gate fixes, and reconciliation. Do not split.
- Commits stay meaningful; add reconciliation commits rather than rewriting reviewed history. Follow the repository's commit identity and trailer rules (no co-author trailer unless it allows one). Confirm `git status` shows no build products, fetched dependencies or secrets.
- Use the repository's PR skill or template if one exists, otherwise [create-pull-request](../create-pull-request/SKILL.md). The body states: what changed (user-visible first), how it was verified (exact gate results; what was not verified on a live system), intentional test or doc changes, historical records left alone, and *Deferred* items.
- Open the PR as a **draft** while CI runs. Poll CI (`gh pr checks --watch` or equivalent). Fix real failures with more commits and re-run until **every required check is green**; never merge, force-push over review, dismiss or bypass a check.
- When all checks are green, mark the PR **ready for review (undrafted)** and confirm the final state: not a draft, checks passing, base current. Merging is the human's decision; do not merge or enable auto-merge.

## 7. Report

Return, briefly: PR URL and state (undrafted, checks green), the gates run and their results, what docs and POC were updated, anything intentionally left alone or deferred, and anything not verified live.
