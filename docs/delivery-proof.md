# Native delivery proof (#54, child of #38)

**Product scope update:** the user confirmed turning this proof into the
installed feature, in one final pull request with its findings. That supersedes
the prototype-only restriction for the installed adapter, existing
controller/setup/resources, tests, global `/maestro` guide and related
documentation. The historical proof remains reproducible, and old
`deliveryProof` records and `a`/`b` routes remain compatible. No live proof
sessions are adopted, restarted or modified.

**Status: native A → B → A delivery observed after human permission approvals,
with unsent draft preservation and editability explicitly confirmed by the
human. A fresh explicit YOLO-launch exchange worked without approval clicks,
and a separate parent-controlled check observed app-background delivery. The
core mechanism is demonstrated, and the pages below list the remaining checks.**
Question: can two Maestro-launched visible Copilot sessions exchange native
prompts without touching human input or changing focus? Source inspection
cannot answer the UI question, and contract tests mock Copilot, so they are not
live proof.

## Contract and boundary

[Contract and boundary](delivery-proof/contract.md)

## Source grounding

[Source grounding and live observations](delivery-proof/source-grounding.md)

### L3 live draft-preservation observation

[L3 live draft-preservation observation](evidence/delivery-proof.md#l3-live-draft-preservation-observation)

### L3 app-background delivery observation

[L3 app-background delivery observation](evidence/delivery-proof.md#l3-app-background-delivery-observation)

### L4 fresh YOLO-launch observation

[L4 fresh YOLO-launch observation](evidence/delivery-proof.md#l4-fresh-yolo-launch-observation)

### Guide distribution decision after live proof

[Guide distribution decision](delivery-proof/guide-distribution.md)

## Parent-only preparation and live launch

[Parent-only preparation and live launch](delivery-proof/live-launch.md)

## Bounded live checks

[Bounded live checks and cleanup](delivery-proof/live-checks.md#bounded-live-checks)

## Local validation and cleanup

[Local validation and cleanup](delivery-proof/live-checks.md#local-validation-and-cleanup)

## Installed implementation and remaining acceptance

### Parent-reported installed exchange and skill-name correction

- [Installed exchange and skill-name correction](delivery-proof/installed-exchange.md)
- [Implementation checkpoint and validation](delivery-proof/installed-validation.md)
- [Installed adapter wiring](delivery-proof/installed-adapter.md)

### Parent-owned installed-product verification

[Installed-product verification](delivery-proof/installed-verification.md)
