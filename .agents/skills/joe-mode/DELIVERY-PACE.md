# Delivery pace

Apply within the human-authorized Joe delivery scope. This repository-local
policy supplements Joe-mode and its CMUX adapter; it grants no new product,
runtime, repository, installation or merge authority.

## Two-hour planning target, not a deadline

Default to a **two-hour elapsed delivery target** for a bounded, independently
useful feature or fix: implementation, acceptance, independent review and
required CI. This is a planning goal, not an execution timeout, guaranteed
service level, permission to skip proof, or a new timer.

Before starting, name the observable outcome, non-goals, owner, acceptance seam,
required checks and known external dependencies in the existing delivery record.
If the work is unlikely to fit, propose an independently useful vertical slice
before dispatch. Obtain the human's agreement when slicing changes the requested
outcome, PR grouping or acceptance. Never silently redefine a partial feature as
complete, or split one outcome into many trivial PRs to improve the metric.

At existing handoff/checkpoint events, compare progress with that target. Escalate
as soon as a blocker, repeated failure or remaining scope makes it implausible,
not only after two hours expire. Return the specific obstacle, evidence, owner,
smallest next action and any actual human decision. Keep useful authorized work
moving; exceeding the target does not kill a command, abandon a lane or waive a
requirement. Do not create scheduled checks just to watch the clock.

Track start, review-ready, required-check completion and merge timestamps.
Report total elapsed time and known externally blocked intervals separately;
do not subtract waiting time from the headline, reset the clock on a handoff,
or invent active-execution time. Live processes, tool calls, messages and tests
run are not delivery velocity. Count accepted outcomes and merges.

## Finish first, with bounded concurrency

Consume returns and advance existing candidates before opening new lanes:
resolve actionable review findings, integrate completed work, publish and obtain
current-head proof. Prefer the nearest valuable finish, not the oldest or
smallest item regardless of impact. A blocked lane does not block independent
work, but launching more work is not a substitute for resolving its bottleneck.

Use the authorized pool, reserving review, test and integration capacity.
Do not expand the pool, close retained sessions, take over another writer or
change model/account defaults to meet the target. An idle peer may take a
bounded assignment only through the supported runtime and explicit custody.

## Coherent test and review batches

The unit of implementation is an end-to-end behavior, not an individual helper,
test assertion or language string. Agree the real production-consumed seam
before tests need it. Where test-first work is selected, obtain meaningful RED
before its corresponding GREEN; compile/setup errors are not behavioral RED.
Batch related cases through that seam instead of a full suite per micro-edit.

Choose the smallest existing command that exercises the changed behavior.
Record which required integrated/full checks will run at the candidate boundary.
Run the required complete checks for the actual final head/base; local focused
passes never replace them. Do not bypass runner restrictions, weaken an oracle,
increase a timeout or label a failure flaky merely to reduce elapsed time.
If no usable focused venue exists, surface that prerequisite early rather than
building repeated speculative scaffolds. New tooling or venue permissions
still require their appropriate scope.

Serialize competing validators on shared mutable fixtures/resources. Reuse
exact-source evidence where inputs, relevant environment and acceptance remain
applicable; say what was reused and what was actually rerun. After a failure,
identify whether it is product behavior, fixture/setup, observation or external
infrastructure before selecting a different check. Preserve the failure.

Obtain one independent whole-deliverable review at a coherent candidate.
Use the same reviewer for focused fix verification and changed-path impact;
retain the original findings and whole-coverage applicability. A new meaningful
scope or uncovered interaction requires additional review, not blind reuse.
Any separately required duck/acceptance role remains independent. Do not add
another identical review or full run just because a result crossed a handoff.

## Routine execution versus human decisions

Kickoff covers ordinary in-scope implementation, coupled fixture/API maintenance,
focused validation, authorized publication and review fixes. The delivery owner
should act without another PM/human vote for each RED/GREEN or constructor change.
Keep one writer per index and use direct supported peer handoffs; PM coordinates
boundaries, not every test assertion.

Ask through the single Discovery conversation for changed product behavior,
scope/grouping, risk acceptance, unknown custody or genuinely missing authority.
Examples include a new visible/interactive test venue, protected shared work,
another repository, credentials, installation or destructive operations.
Distinguish these from routine engineering choices already covered by the task.
An unavailable answer blocks only dependent work; silence is not approval.

Permissions are scoped to actions, resources and conditions. Where that is what
the human authorized, an ordinary subsequent fix commit need not repeat the same
question. An explicitly named immutable-candidate grant or narrower restriction
still requires reconciliation before executing a different candidate.

## Review visibility is not merge eligibility

For Joe-owned deliveries, **draft means unfinished implementation**. Once the
declared implementation is complete, the owner marks the PR ready for review and
verifies provider readback, even if independent review, CI or human acceptance is
pending. Keep those gaps prominent in the PR body; never claim a clean review or
passing check that has not occurred. A newly found missing implementation or
functional repair may require returning to draft with a concrete explanation.

**Ready for review is not ready for final signoff or merge.** The full shared
delivery gate still requires current-base checks, independent review, met
acceptance, no unresolved blocking findings, proper custody and explicit
human-authorized non-author merging. Do not silently narrow a PR's scope to
undraft it or treat a provider's non-draft bit as owner release.

## Reconcile once, then act

Use current candidate/head/base and the latest authoritative artifact section
before acting on a delayed message. Preserve original findings, evidence and
counterevidence; a newer timestamp alone resolves nothing. If the requested work
is already integrated/reviewed, do not replay the old RED, resend its assignment
or rerun its test. Read additional detail only when needed for the next decision.

PM consumes the delivery owner's and Shepherd's scoped evidence; it need not
re-read every transcript, review and raw log. Independently refresh missing,
contradictory or action-critical facts, especially before publication, readiness
and merge. Communicate candidate, review, blocker, decision and merge milestones,
not automatic acknowledgements or repeated "still waiting" messages.

### Decision examples

| Situation | Required action |
| --- | --- |
| Two-hour target is at risk because no test venue is qualified | Escalate the concrete venue decision early; continue independent authorized work, never invent a passing proxy. |
| A late RED arrives after matching GREEN and fix review | Reconcile its exact source and findings, preserve history, and advance the remaining gate; no duplicate repair. |
| An in-scope API change requires a test constructor update | Preserve behavioral oracles and perform the coupled adaptation under existing ownership; no new approval ceremony. |
| Implementation is complete but CI is queued | Mark ready for review with pending checks; do not merge or repeatedly poll/rerun. |
| Tests prove one slice but the requested editor is missing | Keep implementation incomplete; do not call the whole feature done or silently redefine the PR. |
| A new base changes shared behavior | Reconcile integration and review applicability, then obtain required current-head CI; old green is not current proof. |
| A native role loses connectivity | Follow the CMUX reconciliation contract; preserve work and account choices, never spawn a duplicate on uncertain liveness. |
