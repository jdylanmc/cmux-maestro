# Parent-only preparation and live launch

Part of the [native delivery proof](../delivery-proof.md). Previous page is [Guide distribution decision after live proof](guide-distribution.md). Next page is [Bounded live checks and cleanup](live-checks.md).

Do not run these as an unattended test. Use a **new disposable CMUX workspace and
coordinator terminal**, with its actual `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`.
No existing provider sessions are attached, reloaded, or restarted.
The coordinator is human-operated, and both providers are new Maestro workers.

From this isolated checkout:

```sh
ORCH="$PWD/scripts/cmux-maestro-orchestrator.py"
python3 scripts/delivery-proof/fixture.py prepare --name p54
PROOF="$PWD/.build/dp/p54"
"$ORCH" launch-settings
```

Require all four booleans: `accountPinned`, `modelPinned`, `accountAvailable`,
`ready`. Stop on any false value. Do not set test overrides, change the pinned
account/model, copy credentials, or substitute an ambient authenticated client.

Fixture preparation creates two nested disposable Git roots, with discovery
entries only inside them. Source adapter code remains outside automatic discovery.
It refuses existing names, unsafe paths, and Unix socket paths exceeding 100 bytes.

Register **only that disposable coordinator**, privately retaining its returned
identity and token as `COORDINATOR_ID` and `CONTROL_TOKEN`. Do not include the
registration response or token in evidence.

```sh
"$ORCH" register --workspace "$CMUX_WORKSPACE_ID" \
  --surface "$CMUX_SURFACE_ID" --cwd "$PWD" --name "Delivery proof coordinator"

"$ORCH" spawn --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --name "Delivery proof B" --cwd "$PROOF/b" \
  --require-pinned-launch-settings --delivery-proof-fixture "$PROOF/b" \
  --delivery-proof-yolo \
  --task "Disposable delivery proof B. Do no repository work. Wait for a peer message. If it explicitly asks for a reply, use maestro_proof_send once to its sender address. Do not acknowledge other messages or retry. Preserve all existing permission restrictions."

"$ORCH" spawn --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --name "Delivery proof A" --cwd "$PROOF/a" \
  --require-pinned-launch-settings --delivery-proof-fixture "$PROOF/a" \
  --delivery-proof-yolo \
  --task "Disposable delivery proof A. Do no repository work or initial sends. When the human asks, use maestro_proof_peers once and maestro_proof_send once with the requested body. Do not retry or acknowledge replies. Preserve all existing permission restrictions."
```

If extension discovery requires experimental mode, append
`--delivery-proof-experimental` to each **new** spawn command. This adds only
`--experimental` to that provider invocation, not a persistent configuration
change. Verify discovery through each new session's `/env`; honor native trust
prompts and stop on denial. Do not enable test mode to make the experiment pass.

The explicit `--delivery-proof-yolo` opt-in above adds Copilot `--allow-all` to
that **new disposable proof worker only**. It prevents tool/path/URL approval
stalls by granting all three permission categories, except explicit denies.
Omit it to retain ordinary permission prompting. It is refused without
`--delivery-proof-fixture`. Normal workers gain no permissions. This is not
parent-permission introspection or inheritance, a permission callback, or a
persistent Copilot settings change. Native trust or other startup prompts are
not automatically answered.

Verified against the installed CLI's `copilot --help` and
`copilot help permissions`: `--allow-all` and `--yolo` both mean
`--allow-all-tools --allow-all-paths --allow-all-urls`; tool denial rules always
take precedence, including over `--allow-all-tools`. Existing `--deny-tool`
arguments remain unchanged. Recheck provider semantics before using another
version. Do not drop denies if they cannot be preserved.

**Review correction R1:** the original source opt-in checked descendant explicit
allow lists but did not account for the later `--allow-all` flag. A worker actor
with only `read` could request proof YOLO and bypass its grant bound. Both the
preserved `--delivery-proof-yolo` and installed `--yolo` now require a coordinator
actor before credential resolution or reservation. Negative worker-actor tests
cover both forms. Denies and the coordinator's explicit opt-in remain intact.
This is deliberately not full parent-permission inheritance.

Both calls use the existing pinned interactive launcher, native terminal I/O,
exact session ID, and existing explicit tool-policy rules. The opt-in is stored
as `deliveryProof.yolo`; old `{fixture, experimental}` nodes remain valid and
default to no YOLO. The proof options are
source-checkout-only wiring. Nothing is installed over the active integration.
The existing controller store still owns these new workers; no alternate
authentication or replacement control store is created.
