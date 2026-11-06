# Local agent launch settings and per-launch preferences

[↑ Messaging, launch settings, and capacity](../messaging-launch-settings.md) | [← Native-child launch policy](native-child-launch-policy.md) | [Preference refusals and launch selection →](preference-refusals-and-launch-selection.md)

The containing app's **Settings > Agent launches** tab has **Launch agents with
subscription:** and an optional worker-model setting. Dropdown lists
configured GitHub.com accounts from GitHub CLI. It shows no credentials
and infers no subscription plan names. **Use Copilot default** leaves
authentication and model selection to Copilot.

Preferences live only in user's private Application Support
`CMUXMaestroPreview/Orchestration/worker-settings.json`, not in this repository.
Project ships no account or model pin. Launch resolves a configured account from
its stored credential and passes it only through `COPILOT_GITHUB_TOKEN`.
Unavailable credentials fail closed before a new terminal is created. No
silent fallback to a different account. Tokens are not written to settings,
state, launch tickets, arguments, observer files, or logs. Git identity and
active `gh` account are not switched. Changes affect only future workers. Direct
controller callers may keep Copilot defaults by omitting the requirement flag.
Bundled orchestration skill deliberately does not omit it. It always requires the
pinned Maestro account and model.

## Optional per-launch preferences

Native `maestro_spawn` accepts optional `model`, `contextTier` and
`reasoningEffort` strings. Omission preserves existing configured launches:
no model query, no new warning, no context/effort flag. No activity defaults
are inferred from worker names, roles, or task text.

For explicit preferences, existing joined extension reads
`session.rpc.model.list()` using that session's authentication context. It
checks the invoking account before and after. Only bounded model IDs,
supported tiers/efforts, and advertised default effort enter private launch
evidence. Raw model/billing/quota data does not enter state, prompts, or host
commands. Optional option fields are advisory: missing, null, or non-array
fields contribute no options. Arrays are scanned through their first 256 items;
only unique supported CLI strings survive. Unknown strings, numeric tiers,
objects, and other malformed items are ignored, not interpreted as capability
claims. Arrays longer than 4,096 items refuse with the field name, type, length,
and bound, never provider values. Unsupported requested preferences still
produce the controller's visible fallback warning.
Copilot 1.0.100's session API returns raw CAPI entries, not the separate
`models.list` API's typed `Model` objects: efforts come from
`capabilities.supports.reasoning_effort`, and long context from
`billing.token_prices.long_context`. The adapter also retains support for
`supportedReasoningEfforts`, `supportedContextTiers` and
`billing.tokenPrices.longContext` on SDK-shaped entries. Missing defaults stay
omitted; a default is retained only if it belongs to the projected effort set,
never inferred from list order. When both effort representations are arrays,
only their common supported values are admitted; a non-array representation
does not suppress the other representation's verified options.
Malformed model identities, duplicate IDs, oversized or foreign evidence, and account drift
refuse before launch. This is a capability snapshot, not atomic account/provider
admission or an observation of the child's running settings.
