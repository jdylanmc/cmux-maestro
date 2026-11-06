# Plugin and observer hook

[↑ Setup and Copilot integration](../setup-and-integration.md) | [← Installer process and cancellation](installer-process-and-cancellation.md) | [Legacy migration and disable preservation →](legacy-migration-and-disable-preservation.md)

Setup installs distinct, now **hookless `cmux-maestro-native`** plugin and
its bundled skills, private local controller, native loader at
`~/.copilot/extensions/maestro/extension.mjs`, and
**`~/.copilot/hooks/cmux-maestro-observer.json`**, plus the owned CMUX Copilot
hooks **`~/.copilot/hooks/cmux-maestro-cmux-hooks.json`** ([relaunch restore](../relaunch-restore.md)).
The observer is a dedicated version-1 file
declares only `sessionStart`, `userPromptSubmitted` and `postToolUse`, using
unchanged silenced helper wrapper. Private generation/provenance and
advisory setup lock live under existing application `Copilot/` support
directory. Managed tools require matching launcher/session/workspace/generation
bindings. Every Copilot session in CMUX after setup is
[born managed](../../native-messaging/born-managed-sessions.md)
as its own root (ADR 0025). A session already running at setup enrolls in
place at its next extension join (`/clear`, `/resume`, or an extension reload
you run). Maestro never triggers one. `maestro_readiness` reports why a
session is not managed, in plain words. Incomplete launcher inputs keep the nonprivileged
[`maestro_readiness` diagnostic](../../native-messaging/ordinary-session-readiness.md). Existing
`maestro-cmux`, other plugins, provider settings, and sidebar selection
never replaced automatically. Normal app updates refresh owned integration
through coordinated installer. Generated hooks use **stable installed
helper path**, never staging or backup location. Manual moves outside
receipt-owned destination remain unsupported by app installer.

Observer setup attempts **stable Copilot CLI 1.x releases using protocol 3**.
Other major versions, prereleases and protocols remain unsupported. Compatibility
still requires valid public metadata, exact-source identity and verified operation
readback. Version range alone does not establish runtime compatibility.
Conflicting `HOME` or `COPILOT_HOME` is rejected. This does not broaden
reader beyond standard `~/.copilot`. Setup rejects unsafe, symlinked,
hard-linked, modified or foreign owned-target registration and ambiguous owned sources.
It does not chmod existing shared hooks directory.
Historical plugin-hook reformatting also requires review. Provider disable-key
identity can depend on serialization, not just semantically equal JSON.

Before changing existing owned installation, setup submits its exact safe
absolute source path to public plugin-install RPC in private disposable
provider home. On originally tested 1.0.88 and 1.0.89 versions, that source's returned identity
is home-independent. It must match real provider's selection and any prior
receipt before real-home changes. Legacy/name-derived receipts cannot authorize
their own adoption. Request path, provider version/protocol and returned
identity are recorded together. Subsequent install results and discovery must
match. Fresh source is bound and recorded before its first real-home provider
mutation. No private source-ID algorithm or guessed provider directory used.

Unrelated plugin identities and public hook rows preserved. Not audited
through cache aliases or common event names. Live, built-in and opaque unowned
plugins do not cause blanket refusal. Earlier linked-source/safe-cache-alias
counterexample remains evidence that such audit was false. Not evidence of
safe foreign actions. **An independent unowned plugin can still call the current
or an older helper and cause extra executions/writes.** Setup neither certifies
nor suppresses that behavior. Status describes **owned registration** only.
Unsafe owned paths, owned-name/source collisions and directly inspected
user-file conflicts remain targeted refusals.
