# Re-check, installed guide status and acceptance evidence

Part of [CLI guide, enable, and uninstall](../cli-guide-and-uninstall.md). Previous page is [Maestro demo guide and PR acceptance](maestro-demo-and-pr-acceptance.md). Next page is [Acceptance composition and runner](acceptance-composition-and-runner.md).

On opening CLI Integration or choosing **Re-check**, Maestro reads only
`~/.agents/skills/maestro/SKILL.md` (the observed shared global installation)
and `~/.copilot/skills/maestro/SKILL.md` (Copilot's agent-specific global location).
Copies and symbolic links work. Maestro reads only stable regular files up to 64 KiB,
off the main thread. Broken links, unsupported types, access failures
and files changing during a read are reported without changing anything.
Maestro reads no polling, project-skill search, provider configuration or session history.
These are file observations, not evidence of which guide a session loaded,
upstream freshness, observer hooks, observation health or messaging readiness.
Run isolated non-GUI reader/model checks with
`./scripts/test-copilot-setup.sh --guide-only`. Normal setup and hosted test
suites retain full coverage.

## Guide acceptance evidence

Guide rendering/action tests require the isolated GitHub-hosted validation
venue. The two original `CLIIntegrationGuideRenderingTests` acceptance methods
remain executed Swift Testing tests. They now independently validate typed native
observations, not dispatch actions in the integrated app. Two distinct
`GuideAcceptanceTests` XCTest methods produce those observations in the dedicated
guide host **before** the original validators, within the same fresh integrated
invocation. The three original resource/exposure/no-op controls are unchanged.
This approved producer/validator split does not equate a passing result flag
with behavioral evidence.

Failed integrated scopes also retain one bounded `xcresulttool export diagnostics`
archive per exact runner-created `isolated`, `remaining`, or `full-fallback`
result bundle. `coverage.json` records invocation, scope, original test exit,
clean checkout head/tree/raw commit parents, export outcome, archive hash, and
file sizes/hashes. Clean source must agree before execution and before/after
capture. All source reads disable Git replacement objects. Missing or changed
provenance refuses capture. Successful scopes do not
export. Capture never changes selectors, test deadlines, coverage, or failure
status. Capture never retries a test or export.

Read only the named bundle: no home-directory, `DiagnosticReports`, environment,
credential, or process-dump collection. Exported diagnostics can contain synthetic
test output, crash stacks, process names, and runner/source paths. They are
diagnostic evidence, not a sanitized support report. Raw export staging stays
outside artifact globs. Inputs reject links/special files and exceed neither
1 GiB nor 20,000 entries. Exported payloads allow at most 256 entries and 64 MiB
uncompressed, with a 65 MiB archive ceiling per scope (at most two scopes).
Export subprocess has a separate 30-second deadline. These are publication
bounds, not an OS disk quota on export tool's temporary writes.
Export traversal and payload reads use a pinned root directory descriptor and
no-follow directory components. File identity/metadata must agree across
inventory, opening, and reading. Input-bundle and destination checks remain
preflight checks, not a filesystem snapshot or hostile same-user sandbox:
external export tool reopens its input path, and final publication uses the
private invocation directory. Concurrent mutation outside the pinned export
boundary is not comprehensively isolated.
Only completed archives enter `failure-diagnostics/<scope>/<scope>.zip` in the
existing 14-day `integrated-test-scope-evidence` artifact. Missing, empty, oversized,
linked, timed-out, or failed exports record an explicit `unavailable` reason.
Interrupted capture remains `capture-incomplete`. Neither outcome establishes
a faulting thread. A later nonreproduction does not erase an earlier crash.
