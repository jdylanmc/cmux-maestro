# Legacy migration and disable preservation

[↑ Setup and Copilot integration](../setup-and-integration.md) | [← Plugin and observer hook](plugin-and-observer-hook.md) | [Status, failures and messaging configuration →](status-failures-and-messaging-configuration.md)

For recognized direct legacy installation, setup: records provenance
and stages **owned disabled** dedicated file; confirms disabled discovery;
prepares hookless plugin; runs official plugin installer; verifies installed
observer declarations are gone; only then publishes
intended dedicated state. This migration never enables old and new owned observer sources
at same time.
Maestro does not rewrite unrelated hooks or disable keys.
Official CLI does rewrite `settings.json` during plugin install/uninstall,
including when values unchanged. After successful command, setup accepts
only identical settings object or addition of empty `enabledPlugins` map.
All other values, including disable choices and unrelated preferences, must
remain identical. Unsafe or unexpected changes leave setup incomplete.
If setup fails during disabled staging, before resource preparation or any
plugin command starts, it restores and verifies previous owned observer
file and provenance (including prior absence and permissions). Cancellation
waits for that bounded restoration. Changed owned file never overwritten
to force rollback. Resource preparation snapshots all named owned resources
before writing. Later resource-file write failure conditionally restores their
previous bytes, absence and permissions, then restores observer staging when
that restoration is verified. Unchanged resources keep file identity.
Preflight refusal reported as no resource-file writes, not as rollback.
Standalone maintenance reports later incomplete phases conservatively. Normal
alpha installation also uses durable coordinated checkpoint. Failure
or pre-commit interruption restores previous owned files and compensates
provider through official install/uninstall operations at same stable
owned source path. Then verifies public discovery before restoring app.
Rollback restores saved settings bytes only after verifying current values
still match original settings or documented empty-plugin-map
normalization. Unexpected user changes block compensation. Never overwritten.

**Disable preservation is conservative.** Provider omits destination keys
for file-disabled source. When registration change would require mapping
global `disabledHooks`, setup refuses before changing legacy registration.
It neither guesses hashes nor enables duplicate to obtain keys. Change may
proceed with unrelated disables only when complete exact-owned prior metadata
supplies every key, every owned event is enabled, and every configured key is
positively identified as unrelated. Missing/ambiguous keys and affected disabled
subsets still refuse. Settings stay unchanged apart from bounded official
CLI normalization described above. Already
current dedicated registrations keep unchanged hook configuration and
keys. Whole-file/global disable does not bypass unresolved per-key gate:
later re-enabling must not lose disabled subset. Otherwise, explicit
global/file `disableAllHooks` leaves owned file disabled,
including after global flag later cleared. Review owned file and
explicitly change its disable flag before requesting activation again.
No general settings editor or additive disable-key migration. Coordinated
installer's guarded restoration is not permission to accept
arbitrary concurrent settings edits.
