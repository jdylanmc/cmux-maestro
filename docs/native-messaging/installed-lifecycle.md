# Installed lifecycle and permissions

Part of [native messaging: architecture and research findings](../native-messaging-architecture.md). Previous page is [Managed steering and turn boundaries (#163)](managed-steering.md). Next page is [Born managed sessions (#252, ADR 0025)](born-managed-sessions.md).

Explicit production setup installs the native loader, shared adapter, local
controller and lifecycle/icon plugin skills. The global `/maestro` guide is
distributed separately through human-run `npx skills`; native Settings >
CLI Integration only presents and copies the command. Neither guide installation
nor availability is a runtime prerequisite. Managed tools require matching launcher
bindings; ordinary-session diagnostics are separate, as described in
[ordinary-session readiness](ordinary-session-readiness.md).
Newly Maestro-launched visible interactive sessions participate
automatically. Existing/unmanaged sessions are neither adopted nor restarted.
A coordinator without a launcher-bound session cannot receive, and the sidebar sees no bodies or secrets.

New interactive launches precreate the exact workspace/session/generation
binding before CMUX `initial_command` execs Copilot. The one-shot non-login
shell restores the validated PATH and private control environment; subscription
credentials go directly from the bounded account resolver into the process
environment, not the command or a persistent credential file. The canonical
interactive prompt explains capabilities but neither installs nor grants them.

The loader joins the CLI-owned session, validates its actual session ID, then
makes one bounded `native-observe` call. It records the exec-preserved provider
PID/start only after verifying ancestry, current control identity, generation
and host-supplied surface. The controller merges observation either before or
after exact caller attachment without replacing another surface/process owner.
The creation caller does **not** await this call, socket listening, hooks,
provider readiness or prompt consumption. Maestro adds no startup acknowledgement
protocol, retry, adoption, broker or alternate SDK client. A lost create reply
or cancelled attachment retains the launch lease and capacity even if native
observation already occurred. Legacy bindings and loaders keep their existing
path. Existing sessions are not converted or restarted.

The CLI may stop and reload an extension within the same owned session. On
SIGTERM or SIGHUP, the loader cancels its pending local observation and closes only its
own listener/connections before exiting, including during initialization. On
SIGTERM it first waits up to two seconds for an in-flight `/exit` SessionEnd
record. After SIGHUP it records no SessionEnd (see
[Relaunch restore](../reference/relaunch-restore.md)).
The private session binding stays intact for the CLI's replacement extension.
The extension adds no timer, messaging retry or startup acknowledgement. An occupied
socket, or one left behind by forced termination, still fails closed; startup
never unlinks or adopts an existing endpoint. Initialization failures report
bounded allowlisted error codes (for example `EADDRINUSE`), never raw exception
messages, prompts, capabilities or frames.

The launcher retains the configured account/model pins and normal terminal I/O.
Native extension trust/tool prompts remain Copilot-owned. Defaults add no grants;
explicit user-approved coordinator `--yolo` launches may use `--allow-all` while
preserving denies. Worker actors cannot request YOLO for descendants; the reviewed
proof bypass was fixed before credential lookup/reservation. No full parent
permission inheritance, auto-approval callback, or persistent policy rewrite is
inferred. Cleanup must follow exact lifecycle ownership, not a guessed idle state.
