# Dedicated observer registration (#114)

[↑ Behavioral parity and proof](../behavioral-parity.md) | [Observer registration: provider probe evidence →](observer-provider-probes.md)

Explicit setup manages a dedicated version-1 user file for exactly
`sessionStart`, `userPromptSubmitted` and `postToolUse`. The bundled helper,
identity checks, session reader and renderer are unchanged. The lifecycle/icon
plugin remains, without observer declarations. Generation/provenance checks,
bounded descriptor-relative reads, conditional writes, a same-setup lock and
phase-specific results tell missing, stale, disabled, conflicting, incomplete
and current-on-disk registration apart.

Persisted incomplete/conflicting plugin state takes precedence over disable classification.
A completed receipt binds opaque provider-returned event keys to the exact
registration generation/version, so fresh file-only status can tell all from
subset disables. Unknown keys or missing/stale applicability evidence report
unresolved, not ordinary current-on-disk. Check Registration starts no metadata
process. The command-line installer treats verified enabled,
all/subset-disabled and unresolved-applicability completions as success, with
explicit messages. Real errors and usage keep nonzero exits.

Setup attempts **stable Copilot CLI 1.x releases using SDK protocol 3**, with
public metadata, exact-source and operation-readback checks. Other major
versions, prereleases and protocols refuse before registration changes. The
historical live probes in [provider probe evidence](observer-provider-probes.md)
cover 1.0.88 and 1.0.89, not every release the range admits. Setup uses only
`status.get`, `hooks.discover` and `plugins.list` over a new, bounded public
stdio connection. It sends no agent/session creation or model request, never
attaches to an existing session, and shuts the metadata process down after its
three replies. Framing, malformed replies, output limits, timeout, cancellation
and process-group cleanup are checked independently. No private native module
or hash implementation is a product dependency.

Host-only discovery labels this file `hooks/cmux-maestro-observer.json`;
project-scoped discovery uses its absolute path. Only those exact user-origin
labels are recognized, alongside independent file/provenance checks. Arbitrary
relative paths and other origins are not normalized into ownership.
Registration file work and the setup UI's read-only status checks use a
concurrent file-worker queue, not MainActor or the cooperative executor. Each
invocation awaits its own transaction steps; cancellation joins an
already-started writer before returning. This neither serializes the test suite
nor widens the original process-cleanup/readiness deadlines.
