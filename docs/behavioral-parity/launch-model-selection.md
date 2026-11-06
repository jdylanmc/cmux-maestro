# Launch: model selection

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Native-child permissions](launch-child-permissions.md)

Optional launch-selection tests exercise real native assignment forwarding,
sanitized session-scoped model metadata, account rechecking, malformed/foreign
evidence refusal, supported argv and warned configured fallback. Generic omission does not query models, and an unavailable experimental lookup keeps the
prior launch. Model-specific tier/effort fallback keeps a valid selected model.
With no available configured fallback, launch refuses instead of picking
arbitrarily. Root model precedence is unchanged, and new options without joined
evidence warn without injecting unsupported flags. These synthetic source contracts do not observe child model/context settings,
entitlements or a numeric long-context window. Full catalog/billing data is absent from persisted
selection metadata.

For #152, a disposable extension-free SDK session on installed CLI and SDK
1.0.100 returned 23 public model entries. Its raw CAPI snake_case effort and
pricing-tier fields differ from the typed camelCase `Model` shape of
`models.list`. A minimized projection in `scripts/fixtures/model-list-1.0.100.json`
reproduces the earlier loss of all effort/long-context support. Native adapter
tests and the real Python selection/argument path now keep those capabilities
for model-only and model+tier+effort requests. An absent `gpt-5.4-mini`
request warns and falls back to a configured model present in the catalog; it
does not bypass the configured-fallback requirement.

That isolated catalog did **not reproduce** the original installed generic
proof-route refusal. No affected live session was modified or retried, and
#199's root cause remains unproven. Separate negative controls name account
drift, malformed/foreign evidence, the 32-KiB evidence and 64-KiB request
bounds, controller refusal, invalid success/JSON replies and process-output
failure. The real 23-entry projection fits both bounds. These controls tell
failure stages apart but do not show which stage failed in the reported
session. The new parser module takes part in app resources, coordinated setup,
installed readiness and resource-size checks. No live installation is evidence
from this repair; an authorized post-install native attempt is still
outstanding.

Mixed-catalog controls tell valid provider-native effort defaults from
malformed non-advertised defaults before known-CLI projection. Unrepresentable
valid defaults are omitted without poisoning another supported model; a
selected model without a representable default keeps the provider default with
a warning and no fabricated effort argument.

Optional identity-observation regressions exercise the exact joined session's
current model read, account/binding recheck, bounded field projection and
explicit unavailable reasons. Omitted or false `includeModel` does not query the model and keeps the old identity response. Missing effort/context is not filled
from configuration; provider-native safe effort values stay observations, not
invented CLI overrides. Wrong-session calls and account drift refuse. These
mocked SDK responses are source-contract evidence, not an installed-child
demonstration. Spawning still does not wait for an observation. The
failed-attachment capacity fixture stops only its completed synthetic
supervisors, keeps every terminal, and requires the actual configured
resource-limit error, not a busy-store error. Separate live-supervisor capacity
and recovery cases remain intact.

Fixtures are not installed workers, live provider readiness, visible native
acceptance or evidence that the historical host delay is understood. Full
delivery CI and independent review remain separate gates; live host/provider
experiments need a separately authorized release.
