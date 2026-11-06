# Native delivery proof (#54, child of #38)

**Product scope update:** the user confirmed turning this proof into the
installed feature, in one final pull request with its findings. That supersedes
the prototype-only restriction for the installed adapter, existing
controller/setup/resources, tests, global `/maestro` guide and related
documentation. The historical proof remains reproducible, and old
`deliveryProof` records and `a`/`b` routes remain compatible. No live proof
sessions are adopted, restarted or modified. Source inspection cannot answer the UI question, and contract tests mock Copilot, so they are not live proof. [Dated proof status and question](evidence/delivery-proof.md#native-delivery-proof-54-child-of-38).

## Contract and boundary

<a id="contract"></a>
The original **enqueue** proof contract is archived. The current contract is the [chosen Maestro contract](native-messaging/maestro-contract.md) with [managed steering](native-messaging/managed-steering.md). [Archived evidence](evidence/delivery-proof.md#delivery-proof-contract-and-boundary).

## Source grounding

The inspected Copilot sources (`1.0.83`) and the dated L3 and L4 live observations are archived. [Archived evidence](evidence/delivery-proof.md#delivery-proof-source-grounding-and-live-observations).

### L3 live draft-preservation observation

[L3 live draft-preservation observation](evidence/delivery-proof.md#l3-live-draft-preservation-observation)

### L3 app-background delivery observation

[L3 app-background delivery observation](evidence/delivery-proof.md#l3-app-background-delivery-observation)

### L4 fresh YOLO-launch observation

[L4 fresh YOLO-launch observation](evidence/delivery-proof.md#l4-fresh-yolo-launch-observation)

### Guide distribution decision after live proof

<a id="guide-distribution"></a>
Decision: the global `/maestro` guide ships only through a human-run `npx skills` command. Current contract: [CLI guide, enable, and uninstall](reference/cli-guide-and-uninstall.md). [Archived evidence](evidence/delivery-proof.md#guide-distribution-decision-after-live-proof).

## Parent-only preparation and live launch

<a id="live-launch"></a>
The parent-only disposable workspace preparation and the two proof launches that reproduce the historical `a`/`b` proof are archived. [Archived evidence](evidence/delivery-proof.md#parent-only-preparation-and-live-launch).

## Bounded live checks

<a id="live-checks"></a>
[Bounded live checks and cleanup](evidence/delivery-proof.md#bounded-live-checks)

## Local validation and cleanup

[Local validation and cleanup](evidence/delivery-proof.md#local-validation-and-cleanup)

## Installed implementation and remaining acceptance

### Parent-reported installed exchange and skill-name correction

<a id="installed-exchange"></a>
The dated installed A -> B -> A exchange and skill-name correction are archived. The cause of the initial missing-inventory observation remains unresolved. [Archived evidence](evidence/delivery-proof.md#parent-reported-installed-exchange-and-skill-name-correction).

<a id="installed-validation"></a>
The implementation checkpoint and its dated targeted validation results are archived. The parent owns final complete CI, independent review, installed live validation and installed Settings UI acceptance. [Archived evidence](evidence/delivery-proof.md#installed-implementation-checkpoint-and-validation).

<a id="installed-adapter"></a>
The #54 installed-adapter wiring record is archived. Current contract: [installed lifecycle and permissions](native-messaging/installed-lifecycle.md) and [chosen Maestro contract](native-messaging/maestro-contract.md). Uninstall removes the entry point and new-launch configuration, not live bindings/adapters. [Archived evidence](evidence/delivery-proof.md#installed-adapter-wiring).

### Parent-owned installed-product verification

[Installed-product verification](delivery-proof/installed-verification.md)
