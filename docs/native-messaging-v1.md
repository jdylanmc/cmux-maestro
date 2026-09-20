# Native messaging v1 — bounded, opt-in delivery

This is a limited implementation slice of #38, **not closure of the issue**.
Offline tests exercise the protocol and fake SDK; they do not prove a particular
installed Copilot build delivers messages or presents human authorization.

## Setup and launch

Only a human using the installed production Maestro app can enable the optional
**Native Messaging** setup. Enable the base Copilot integration first. Native
setup installs `~/.copilot/extensions/cmux-maestro-native-messaging/`, preserving
the standard Copilot configuration home, account resolution, model selection,
project configuration and native managed policy. Alternate `COPILOT_HOME` and
`XDG_CONFIG_HOME` are unsupported. No project `.github` directory is changed.
Validation builds cannot install, approve or verify production authorizations.

**Ad-hoc builds cannot use native messaging.** The ordinary `build-register.sh`
and `local-preview.py` ad-hoc workflow remains supported for other features.
Its bundle ID alone does not qualify it for persistent Secure Enclave keys.
Enable, request preparation, signing and native spawn fail closed unless the
app passes runtime signing/provisioning qualification. Disabling remains possible.
Preparation requires enabled setup, not merely pinned launch settings.

### Optional, locally provisioned development build

This is an explicit production-namespace build, **not an offline validation
command**. First, the human developer must use their Apple Developer account to
set up an **Apple Development** identity and matching installed macOS development
profiles for these two explicit identifiers:

- `com.jdylanmc.CMUXMaestroPreview`
- `com.jdylanmc.CMUXMaestroPreview.Extension`

Both profiles must authorize the same signing certificate and Team ID, include
this Mac, and be current. The app profile must authorize its one private
`<AppIdentifierPrefix>.com.jdylanmc.CMUXMaestroPreview` keychain access group.
The extension retains its existing sandbox/read-only grants and receives no
keychain group. The helper is signed by the same identity without new grants.
Its exact code-signature namespace uses `PRODUCT_BUNDLE_IDENTIFIER` and explicit
`codesign --identifier`. Xcode can synthesize an application-identifier entitlement
even with base entitlement injection disabled or an empty bundle identifier;
neither setting is an entitlement-removal mechanism. The helper has no Xcode
source entitlement file or third profile.
There is no special `com.apple.developer.secure-enclave` entitlement.

After explicit local build consent, supply these **local environment variables**:
`CMUX_DEVELOPMENT_TEAM`, `CMUX_DEVELOPMENT_IDENTITY` (full `Apple Development: …`
identity), `CMUX_NATIVE_APP_PROFILE` and `CMUX_NATIVE_EXTENSION_PROFILE` (installed
profile names or UUIDs). Then run `./scripts/build-development.sh`. No personal
team, identity or profile values belong in repository defaults. The script uses
manual signing, checks resolved namespaces before a clean build, and checks signed
components, effective entitlements and embedded profile metadata afterward.
Between the Xcode build and final verification, `sign-development-helper.py`
checks generated paths, namespaces and the selected signer, refusing any helper
privileges beyond the known exact application identity and optional Boolean
debugging grant. It then signs the top-level helper with that same explicit
identity, its exact `.CopilotHook` identifier, hardened runtime,
`--timestamp=none` and the checked-in **empty** `helper-development.entitlements`.
After verifying zero helper entitlement keys, it embeds that identical helper
and re-signs the enclosing app with
`--preserve-metadata=identifier,requirements,entitlements,flags,runtime` and
`--timestamp=none`. App entitlements and both embedded profiles are retained;
the extension is not re-signed. Any failed step stops the build before success.
The existing strict development verifier remains the final gate; this packaging
step does not establish runtime readiness, install the app or grant permissions.
The clean is scoped to this checkout's `.build/development` derived products so
an incrementally cached, copy-on-sign embedded helper cannot retain old grants.
It never creates/imports certificates, downloads profiles or uses
`-allowProvisioningUpdates`. Output is in `.build/development`.

It neither copies an app into Applications nor explicitly invokes `pluginkit`,
but **Xcode may register the source app with LaunchServices during build**.
Installation/registration and enabling the global loader require separate human
consent. The existing receipt-based `local-preview.py` installer intentionally
accepts only ad-hoc builds; do not send this development build through it or
weaken that policy. A signed local installation procedure is still a separate
manual step. This is not a distribution/notarization workflow. Developer ID
Application is not categorically incapable of keychain use; this optional
script specifically targets Apple Development provisioning.

Runtime qualification uses macOS code-signature validation and an Apple-issued
signing requirement, the exact app/extension identities and common team,
authenticated embedded profile contents, profile dates and signing-certificate
membership, and matching effective identity/keychain entitlements. No
user-configurable “ready” flag can replace these checks. It also checks Secure
Enclave availability and whether macOS user authentication can be evaluated,
without creating a key or presenting an authentication prompt. The
`--maestro-native-readiness` entry point only returns supported/unsupported;
it is not an approval command. Packaging checks alone are **not** live readiness.

Key creation **and existing-key lookup** explicitly select the data-protection
keychain (`kSecUseDataProtectionKeychain`), not macOS's default file keychain.
Verification-only processes prohibit authentication interaction, look up the
existing private-key reference without creation, and verify with its public key;
they never sign. Actual key lookup/signing can still fail when locked or denied:
there is no software-key fallback, automatic prompt approval or retry that
weakens user presence.

Apple references: [macOS keychains (TN3137)](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
and [certificate types](https://developer.apple.com/help/account/certificates/certificates-overview).
The supplementary profile-metadata checks are deliberately narrow and may need
updating as Apple changes profile formats; the operating system, not a parsed
property list, remains the authority for restricted entitlements
([TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)).

Setup does not restart or adopt sessions. The global loader exits before SDK
join/tool registration unless the provider-supplied `SESSION_ID` equals the
explicit launch binding. A private, generation-scoped bridge capability is
authenticated by the existing locked controller. The controller additionally
checks the bounded process chain from its adapter caller to the exact live
provider PID/creation stamp recorded by the launcher. Supported paths are
adapter → provider directly, or adapter → packaged `copilot` executable →
recorded provider wrapper. Parent edges, executable identity and creation stamps
are sampled again before acceptance; missing, stale, reparented, unrelated and
deeper chains fail closed. This process check supplements, and never invents,
the logical session/worker/run/generation identity. A filesystem path or SDK
`source` string alone is not authentication. No provider credentials are requested
from the SDK, and no permission/user-input callbacks are registered.
New native supervisor and provider anchors carry the explicit `ps-c-utc-v1` start format:
capture, liveness and every ancestry resample run `ps` in the C locale and UTC,
then strictly parse its creation stamp into UTC. Caller locale/time zone and the
bridge's reduced environment cannot change that representation. The supervisor
anchor is captured before publishing the running phase, so authenticated adapter
registration returns `starting` while provider attachment is pending, and status
does not mistake that launch window for a disappeared process. Runtime ownership
and exit cleanup compare the full anchor, including its format. Existing
unversioned provider/supervisor anchors retain their original local-string
handling; no timezone is guessed and no global process-stamp migration occurs.

Use `prepare-native` with the same actor, name, task, cwd and exact allow/deny
arguments intended for `spawn`. Both pinned launch settings are required.
Preparation creates a bounded private request, not a terminal. Open Maestro's
**Agent launch settings → Native messaging child authorization**, refresh, and
review the exact request including account/model, task, parent identity, child
worker/session IDs, directory, inherited denies and requested tools. Only
opted-in native workers pass Copilot's per-launch `--experimental` flag.
Ordinary workers and global `~/.copilot/settings.json` remain unchanged.

The review list puts valid pending run-policy requests first. Rows show the
initial worker/task label and status, with a short request ID secondary; labels
are bounded, control/direction-filtered metadata, never proof of authority.
Expired, not-yet-valid, legacy, unsupported, reuse-ticket and receipt-present
rows cannot be signed. Status uses the same schema/scope/time validation as
signing; recognizing a reuse ticket for display does **not** admit it to the
signing validator. A receipt-present label means safe read and exact request
binding, **not** cryptographic verification or confirmation of an unused ticket.
Reuse-ready labels likewise describe the ticket, not current grant validity or
admission. The controller still checks all launch conditions. Nothing is pruned
automatically.

The sheet summarizes directory, account/model pins, explicit requested and known
parent allows/denies, and exact actor/coordinator/run/workspace identities.
Full source JSON remains available in a disclosure; display-only escaping never
changes signed bytes. The disclosure continues to explain that matching future
tasks and labels may vary. These CLI flags are neither an OS sandbox nor a full
effective-native-permission export.

Failures stay **inside the active sheet** with actionable stage/status codes:
readiness, validation/expiry, safe request read, key access, signing (including
source-reported authentication cancellation), receipt write or exact read-back.
Only allowlisted error-domain labels and numeric system codes are shown, not raw
backend errors, authentication details or key material. **Run policy approved —
ready for launch** appears only after the written receipt is safely read back
byte-for-byte; it never claims a worker launched. Failed read-back explicitly
warns that a receipt may exist without confirmed success. Going back without
approving is not success; destructive **Remove request and receipt** has its own
outcome and does not revoke already-active run-policy grants. Authentication,
Secure Enclave operations, protections and controller authority are unchanged.

Routine setup and approval controls have explicit accessibility labels and
stable identifiers, avoiding positional button selection. Setup uses
`copilot-setup-*` / `native-setup-*` (including distinct install/uninstall and
enable/disable confirmation targets); launch settings uses `agent-launch-settings`.
Approval uses `native-authorization-refresh`, `native-authorization-review-<requestId>`,
`native-authorization-approve`, `native-authorization-remove` and
`native-authorization-back`. Status, result, error and details are also identified.
Review accessibility values include status and the exact request ID, independent
of row order or possibly duplicate worker labels. These are UI metadata, not
permission or automation grants; macOS authentication still requires user presence.
Offline tests check compilation and identifier contracts, not live AX exposure.

Full authoritative parent-policy export is unavailable. The displayed request
explicitly asks the human to authorize a child policy instead; it does not claim
to have reconstructed effective permissions from `getMode`, defaults or partial
events. This version supports only explicit exact-tool flags, with known denies
winning and descendant grants constrained by the existing parent tool policy.
Allow-all, path/URL-policy emulation and additional policy fields are unsupported.
The provider remains responsible for its native managed restrictions.

**Authorize run policy…** signs the exact displayed v2 request bytes with a non-exportable Secure
Enclave key requiring macOS user presence. There is no software-key fallback and
no controller command, boolean or environment override that approves a request.
Machines lacking that facility cannot use this launch mode. The app's
verification-only entry point cannot create an approval. Like the existing
controller, this trusts the installed app/controller and the user's OS account;
it is not a sandbox against a hostile same-user process replacing installed code
or configuration.

The signed bytes explicitly declare `approvalScope: run-policy` and disclose
that future matching workers may have **different tasks and labels**. Consent
is actor-specific, not a grant to all descendants or peers. It binds the actor
and real coordinator identities/authority, run, workspace, canonical directory,
pinned launch settings, known parent policy and effective requested allow/deny
policy, and an enabled-setup identity. Native policy is still authoritative.

Preparation returns `human-authorization-required` on the first request. Pass
its ID as `spawn --native-request ID` with the same launch arguments after the
human signs it. The controller verifies the fresh pending request's signature
and atomically caches the narrowly scoped grant and consumes that launch ticket
with the existing launch lease. Each pending request/ticket expires after ten
minutes; an activated grant lasts only for its active run and exact scope,
independently of that first request's timeout. An expired request cannot activate
a grant.

For the next worker, call `prepare-native` again. If the exact snapshot still
matches, it returns `reuse-ready` with a **new** worker/session/request ticket
referencing the previously verified grant; no new human authentication is needed.
Use that ticket once with its exact name/task and arguments. Replayed or expired
tickets are refused, including uncertain retries and launches that failed after
reservation. A policy grant is not an idempotency override. Settings and setup
are checked again at admission. Changed scope needs fresh consent; archive and
recovery remove grants, while disabling/re-enabling setup rotates its identity
and makes prior grants/tickets unusable. Stale coordinator/worker ownership
cannot reuse consent. Existing workers are never mutated or restarted.
Fresh grant activation also invalidates different scopes for that actor inside
the same locked ticket-consumption/launch-reservation transaction, even when both
requests were prepared and signed before either launch. Other actors' grants and
exact-scope grants remain intact. A superseded grant's previously prepared reuse
ticket is refused, not promoted back into a grant. Rejected reservations do not
persist grant invalidation or ticket consumption.

Legacy v1 single-worker requests/receipts are rejected, **never promoted**.
Their consumed-ticket tombstones retain their existing timeout semantics.
Enable native setup in the updated signed app before preparing v2 requests;
legacy setup records without a setup identity are unsupported. Messaging itself
remains protocol v1. The signing pipeline and Secure Enclave key are unchanged.

At most 16 request files are retained, including reusable launch tickets.
Remove reviewed/consumed requests explicitly in the UI. Run-policy grants are
bounded to 128 private records and never enter the observer projection.
Disable Native Messaging to make future loader executions inert and prevent
new authorized launches; this does not terminate existing opted-in sessions.

## Versioned coordinator loop

`native-message` accepts **one bounded JSON object on stdin**, never message
bodies or bridge credentials in argv. It uses the existing coordinator/worker
control token and permits only direct parent-to-owned-child delivery. Each request
includes `version: 1`, `operation`, `actorId`, `token`, and the exact receiver:

```json
{
  "nodeId": "<workerId>",
  "sessionId": "<sessionId>",
  "generation": 1,
  "runId": "<runId>"
}
```

Obtain these from authenticated `status`/spawn, not titles, focus, directories,
process guesses or transcript contents.

1. `operation: "capabilities"` must report `status: "supported"` for this exact
   identity. A missing, stale, disconnected, legacy or non-opted-in adapter is
   explicitly unsupported. Protocol/version/identity errors are explicit errors.
2. `operation: "send"` additionally supplies `key` (1–128 UTF-8 bytes), `body`
   (1–4096 UTF-8 bytes), and `ttlSeconds` (1–3600). Persist the sender's key and use
   **the same key, body, target and TTL** for uncertain controller-request retries.
   Mismatched duplicates are rejected. Do not create a new key to “retry” a turn.
3. `operation: "read"` returns only this sender/receiver pair's explicit messages.
   The receiver uses native `maestro_acknowledge(messageId)` and
   `maestro_reply(messageId, body)` tools. Replies are explicit model statements,
   not inferred final output. One reply per message; identical retries are safe.
4. Decide next work from explicit replies and independent task evidence. A
   delivery receipt does not mean the task succeeded or even began execution.

Coordinators have a registered control identity, not a claimed native Copilot
session. Their envelope explicitly has `sessionId: null`; SDK source labels use
`agent-maestro-controller-<nodeId>`. Worker senders additionally carry their exact
controlled session UUID. Neither source label is used for authorization.

| State | Meaning |
|---|---|
| `queued` | Durably admitted, not yet offered to the adapter |
| `inflight` | Durable claim precedes SDK send; acceptance may be unknown |
| `delivered` | `session.send({mode:"enqueue"})` returned a provider message ID; **acceptance only** |
| `acknowledged` | Receiver explicitly called the acknowledgement tool |
| `replied` | Receiver explicitly supplied a bounded reply; no automatic lifecycle transition |
| `unknown` | Acceptance was uncertain; the adapter must never resend this message |
| `expired` | TTL passed before sending; no new turn should be created |
| `rejected` | Queued message's ownership/generation became invalid |

One adapter polls serially. Inflight/unknown messages block later sends for their
sender/receiver pair until explicit acknowledgement or reply resolves uncertainty.
SDK acceptance does not claim ordering of task completion or exclusivity against
human input. Real terminal I/O stays native and `enqueue` does not paste into it.
SDK acceptance is bounded to 15 seconds before uncertainty; controller requests
are bounded to five seconds. No SDK send is automatically repeated.

There are at most **64 unarchived message records**, not 64 free-to-recycle queue
slots. Bodies/replies are scrubbed after 24 hours on the next native operation;
bounded identity/key/content-digest tombstones remain until explicit run archive.
This preserves deduplication and uncertain-message ordering even after payload
retention. Archive clears the run's records and bridge tickets. No background
retention daemon exists. Queues can deliberately refuse admission rather than
evict a deduplication key. Closing/archiving runs remains a human-controlled
lifecycle operation, never automatic capacity recovery.

The adapter registration is generation-bound and non-transferable. A second
registration after crash, reload, `/clear` or foreground replacement is refused.
Disconnects become unsupported; existing messages may remain inflight/unknown.
There is no adoption, restart, unsafe replay or automatic process cleanup.

## Boundaries and validation

- Existing explicit-tool `spawn`, legacy bounded workers, resource limits,
  launch leases, direct human terminal use and sanitized sidebar projection remain.
- No arbitrary peers, transcript sharing, output scraping, terminal injection,
  permission approval hook, sidebar control plane or additional daemon.
- Messages, replies, credentials and policy requests remain outside observer data.
- SDK contract reference: cached Copilot CLI 1.0.87 extension declarations and
  `copilot-sdk/docs/extensions.md`. This integration is provider-version-sensitive.
  A different loader/process topology fails closed instead of guessing ownership.

Offline commands:

```sh
python3 scripts/test-maestro-native.py
node --test scripts/test-native-adapter.mjs
python3 scripts/test-build-metadata.py
./scripts/test.sh -only-testing:CMUXMaestroPreviewTests/NativeMessagingTests
./scripts/test-copilot-setup.sh
python3 scripts/test-cmux-maestro-orchestrator.py
```

Live validation requires separate human approval of installation/setup and a new
run-policy request. The implementation task does **not** authorize installation or paid
inference. After that approval, the operator should verify pinned account/model,
runtime qualification, first-key creation and OS-mediated policy signing, then
existing-key reuse and noninteractive verification in a separate process,
one freshly launched worker, then a second matching worker with a new
`reuse-ready` ticket and no additional authentication, bounded send,
idempotent retry, explicit acknowledgement/reply, human-typed input, expired
message refusal and disconnect uncertainty. Capture only explicit message IDs,
receipts and intentionally supplied test bodies, not general session transcripts.
Keep provider acceptance and task-result evidence separate. Do not call #38
complete based on offline tests or SDK acceptance alone.

The remediation has only offline synthetic profile/signature tests and unsigned
validation builds. A paid membership alone is insufficient: the required local
Apple Development identity and two installed profiles must exist before a
signed proof. No signed build, installation, keychain mutation or live inference
is claimed by these tests. CI runs the Python native-controller and dependency-free
Node adapter tests alongside the existing checks; Swift qualification tests use
synthetic metadata and cannot authorize production operations.
