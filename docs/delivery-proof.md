# Native delivery proof (#54, child of #38)

**Product scope update:** the user confirmed conversion of this proof into the
installed feature, in one final pull request with its findings. The prototype-only
restriction is superseded for the installed adapter, existing controller/setup/
resources, tests, global `/maestro` guide and associated documentation. The historical
proof below remains reproducible; old `deliveryProof` records and `a`/`b` routes
remain compatible. No live proof sessions are adopted, restarted or modified.

**Status: native A → B → A delivery observed after human permission approvals;
unsent draft preservation and editability explicitly confirmed by the human.
Fresh explicit YOLO-launch exchange also demonstrated without approval clicks.
App-background delivery observed in a separate parent-controlled check.
Core mechanism demonstrated. The remaining checks are listed in the pages
below.**
Question: can two Maestro-launched visible Copilot sessions exchange native
prompts, without touching human input or changing focus? Source inspection cannot
answer the UI question. Contract tests mock Copilot and are not live proof.

## Contract and boundary

The extension joins its exact session and enqueues one native prompt per send.
See [contract and boundary](delivery-proof/contract.md).

## Source grounding

The inspected Copilot sources and the live L3 and L4 observations are in
[source grounding and live observations](delivery-proof/source-grounding.md).

### L3 live draft-preservation observation

See [L3 live draft-preservation observation](delivery-proof/source-grounding.md#l3-live-draft-preservation-observation).

### L3 app-background delivery observation

See [L3 app-background delivery observation](delivery-proof/source-grounding.md#l3-app-background-delivery-observation).

### L4 fresh YOLO-launch observation

See [L4 fresh YOLO-launch observation](delivery-proof/source-grounding.md#l4-fresh-yolo-launch-observation).

### Guide distribution decision after live proof

The global `/maestro` guide ships only through a human-run `npx skills`
command. See [guide distribution decision](delivery-proof/guide-distribution.md).

## Parent-only preparation and live launch

Disposable workspace preparation and the two proof launches are in
[parent-only preparation and live launch](delivery-proof/live-launch.md).

## Bounded live checks

Single synthetic sends under focus, draft and background conditions are in
[bounded live checks and cleanup](delivery-proof/live-checks.md#bounded-live-checks).

## Local validation and cleanup

See [local validation and cleanup](delivery-proof/live-checks.md#local-validation-and-cleanup).

## Installed implementation and remaining acceptance

### Parent-reported installed exchange and skill-name correction

- [Installed exchange and skill-name correction](delivery-proof/installed-exchange.md)
- [Implementation checkpoint and validation](delivery-proof/installed-validation.md)
- [Installed adapter wiring](delivery-proof/installed-adapter.md)

### Parent-owned installed-product verification

The remaining parent-owned acceptance steps are in
[installed-product verification](delivery-proof/installed-verification.md).
