# Launch: model selection

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Native-child permissions](launch-child-permissions.md)

Optional launch-selection tests exercise real native assignment forwarding,
sanitized session-scoped model metadata, account rechecking, malformed/foreign
evidence refusal, supported argv and warned configured fallback. Generic
omission performs no model query; unavailable experimental lookup preserves
the prior launch. Model-specific tier/effort fallback retains a valid selected
model. No available configured fallback means refusal, not arbitrary selection.
Root model precedence stays unchanged, and new options without joined evidence
warn without injecting unsupported flags. These are synthetic source contracts,
not observed child model/context settings, entitlements or a numeric long-context
window. Full catalog/billing data is absent from persisted selection metadata.
For #152, a disposable extension-free SDK session using installed CLI and SDK
1.0.100 returned 23 public model entries. Its raw CAPI snake_case effort and
pricing-tier fields differ from `models.list`'s typed camelCase `Model` shape.
A minimized projection in `scripts/fixtures/model-list-1.0.100.json` reproduces
the previous loss of all effort/long-context support. Native adapter tests and
the real Python selection/argument path now preserve those capabilities for
model-only and model+tier+effort requests. An absent `gpt-5.4-mini` request warns
and falls back to a configured model present in the catalog; it does not bypass
the configured-fallback requirement.

The original installed generic proof-route refusal was **not reproduced** by
that isolated catalog. No affected live session was modified or retried; #199's
root cause remains unproven. Separate negative controls name account drift,
malformed/foreign evidence, the 32-KiB evidence and 64-KiB request bounds,
controller refusal, invalid success/JSON replies and process-output failure.
The real 23-entry projection fits both bounds. These controls distinguish
failure stages. They do not establish which stage failed in the reported session.
The new parser module participates in app resources, coordinated setup,
installed readiness and resource-size checks. No live installation is evidence
from this repair. An authorized post-install native attempt remains outstanding.
Mixed-catalog controls distinguish valid provider-native effort defaults from
malformed non-advertised defaults before known-CLI projection. Unrepresentable
valid defaults are omitted without poisoning another supported model; selected
models without a representable default retain the provider default with a warning
and no fabricated effort argument.
Optional identity-observation regressions exercise the exact joined session's
current model read, account/binding recheck, bounded field projection and explicit
unavailable reasons. Omitted or false `includeModel` performs no model query and
preserves the old identity response. Missing effort/context is not filled from
configuration; provider-native safe effort values remain observations rather
than invented CLI overrides. Wrong-session calls and account drift refuse.
These mocked SDK responses are source-contract evidence, not an installed-child
demonstration. Spawning still does not wait for an observation.
The failed-attachment
capacity fixture stops only its completed synthetic supervisors while retaining
every terminal, and requires the actual configured resource-limit error, not a busy
store error. Separate live-supervisor capacity and recovery cases remain intact.

Fixtures are not installed workers, live provider readiness, visible native
acceptance or evidence that the historical host delay is understood. Full
delivery CI and independent review remain separate gates; live host/provider
experiments require a separately authorized release.
