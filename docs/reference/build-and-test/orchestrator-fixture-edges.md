# Orchestrator fixture edges

[↑ Build and test](../build-and-test.md) | [← Isolated setup, hook and sandbox checks](isolated-setup-hook-and-sandbox-checks.md)

The shipped orchestrator reads no test variables and has no testing mode.
Worker admission's parent-evidence check and identity-helper proof always run.
Fixture launches use `native-spawn` from a coordinator holding managed-session
evidence: a live synthetic provider, a recorded launch policy and its adapter's
private route. Tests about runs from before that admission seed a registered
root explicitly. The Python suites fake only the outside world:

- `HOME` selects the synthetic Orchestration and Beats stores.
- `PATH` supplies synthetic `cmux`, `copilot` and `gh` executables.
- An installed-style `identity-helper.json` beside a copied controller selects
  a synthetic identity helper.
- The synthetic host (`FAKE_ATTACH_BARRIER`, `FAKE_ATTACH_FAILURE`) holds or
  fails the creator's first `identify` of a new surface.
- `controller-fixture.py`, written by `scripts/test-cmux-maestro-orchestrator.py`,
  applies `scripts/test-fixtures/orchestrator-controller-edges.py`, the only
  reader of `FAKE_STARTUP_SECONDS`, `FAKE_HEARTBEAT_SECONDS`,
  `FAKE_ARCHIVE_SECONDS` and `FAKE_GIT`. It also becomes the re-entry point for
  runtimes and terminals. It loads the controller and those edges, not the whole
  suite, through one run-scoped bytecode cache.

Worker Copilot processes receive only the controller's `CMUX_MAESTRO_`
allowlist. Bounded runtimes build the provider environment without any inherited
`CMUX_MAESTRO_` key. A direct launch's sourced script resets each allowlisted
name and the recorded launch `PATH`, then `exec`s the controller's `direct-exec`
bootstrap. It builds the provider environment as a mapping that drops every other
`CMUX_MAESTRO_` key, including names that are not shell identifiers, and
`execve`s the provider in place. Other variables such as `HOME` pass through.

The orchestrator suite uses fake CMUX/Copilot processes in temporary roots.
Its fixture-only Python startup hook carries a shared lifetime descriptor
through subprocesses and shell execution. Teardown closes fixture admission,
signals only recorded PID/start identities, and requires exclusive lifetime
ownership before deleting the root. A writer that outlives the existing
three-second shutdown budget causes an explicit failure and preserves the
sandbox, including against automatic temporary-directory cleanup. Do not remove
a preserved root until its exact fixture processes have stopped. New fixture
launch paths must preserve the lifetime descriptor and startup hook; neither
is installed into real CMUX or Copilot sessions.
