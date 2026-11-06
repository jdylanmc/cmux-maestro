# Installer process and cancellation

Part of [Setup and Copilot integration](../setup-and-integration.md). Next page is [Plugin and observer hook](plugin-and-observer-hook.md).

Containing app = installer, not session observer. Close it
after setup. **Check Registration** reads only registration files. Successful
setup verifies dedicated file and hookless installed plugin on disk and
through provider discovery. It does not imply loaded hooks, observed events,
messaging readiness or enabled host extension.

Installer invocations start in own process group. **Cancel Setup** and
45-second timeout stop that invocation's launcher and descendants, then
wait for cleanup before permitting retry. Existing Copilot sessions never
signalled. Same applies to bounded, metadata-only `status.get`,
`hooks.discover` and `plugins.list` checks during explicit setup. Each process
has same deadline. Setup starts no agent/model session or persistent
service. Metadata output capped at 256 KiB. Never displayed as raw
CLI output.
Setup passes `--no-auto-update`. Plugin change does not opt into upgrading
selected CLI.

Before each metadata or plugin operation, including isolated source-identity
bootstrap, setup probes the selected runtime with `--no-auto-update --help`.
The help probe uses the same bounded process supervisor and coordinated install
lease. Its output is capped at 256 KiB and never displayed. Package metadata is
not runtime evidence: a CLI loader can dispatch a newer cached executable.
Recognized legacy help uses `--no-remote --no-remote-export`. Copilot CLI
1.0.103 help advertises `--sync-session[=<on|off>]`; setup uses
`--sync-session=off` instead. Unknown controls refuse before any metadata or
plugin RPC. Setup never retries without privacy flags and makes no persistent
setting change.

In 1.0.103, history sync otherwise uses configured/default behavior; sync does
not itself enable incoming control. Remote control is separate (`/remote`,
`/environments`, explicit host/connect options). Setup runs only its private
headless stdio metadata/plugin transport: it neither creates/resumes a session
nor requests hosting or connection. Disabling sync is not a general network
sandbox. This compatibility choice follows the runtime's `--help`, removed-flag
diagnostics and [1.0.103 release notes](https://github.com/github/copilot-cli/releases/tag/v1.0.103).

Interactive spawn/resume and legacy prompt launches do not pass the removed
flags. Their existing launch policy is unchanged. The native adapter reads the
current session's model catalog rather than launching another provider.
The coordinated installer displays only allowlisted, fixed Maestro bridge
failure reasons; other stderr is withheld, never echoed as raw CLI output.
