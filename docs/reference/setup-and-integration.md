# Setup and Copilot integration

What install does to Copilot, what it refuses, how disable and rollback behave. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

<a id="cmux-maestro"></a>

## Sidebar overview

Compiled macOS CMUX sidebar. Shows Copilot sessions and explicit
terminal-backed orchestration hierarchies. Native sidebar reads locally. No companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
Separate interpreted Maestro project untouched. Not a dependency.

See [behavioral parity matrix](../behavioral-parity.md) for regression
evidence, live acceptance scope, intentional differences, remaining limits.

Sidebar path labels use real user's account home (`~` or `~/…`). Applies to
workspace/project paths, surface directories, hover and pinned details.
Formatting normalizes separators and dot components lexically. Never
probes filesystem. Never resolves symlinks. Outside paths stay absolute.
Missing/denied states stay explicit. Ownership/navigation values unchanged.
Account-home resolution failure: absolute label explains it.

**Surface directory** = directory CMUX reports for that exact
surface. Not independently verified agent process or last-tool working
directory. **Parent surface directory** = parent placement only. Not a
windowless child's own directory. Help and accessibility keep this source
qualification and the absence of a report timestamp. Fresh session observation
does not establish directory-report age. Assigned/last-verified Git worktree
labels are separate evidence, never directory fallbacks. Retained original
sessions do not borrow replacements' paths.

At pinned SDK/host revision `ae7fbce99f98c98df5ccf915e548dd080d33cfa8`,
[`CmuxSidebarSurface.workingDirectory`](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarSurface.swift)
is optional. `workspacePaths` filters it.
The [sidebar producer](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/ContentView.swift#L12736-L12748)
uses `reportedPanelDirectory(panelId:)`. Its
[implementation](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/Workspace%2BSidebarDirectories.swift#L48-L70)
normalizes panel report and applies remote trust gating. It does not use
separate `effectivePanelDirectory` local/requested-directory fallback.
Source-level provenance only. Not installed-host acceptance of #77 or
runtime-directory collection.

## One-time setup

1. Use [alpha installer](install/local-preview.md). Normal install
   and update include Copilot automatically. Separate setup action not
   required. Installer uses configured `PATH`, or explicit trusted
   `--copilot-executable /absolute/path/to/copilot`. It does not assume shell
   startup files or machine-specific provider cache paths.
2. Containing app keeps **Enable Copilot Integration** and
   **Choose Copilot…** for explicitly requested maintenance. These controls are
   not normal-install prerequisites. Production app also keeps the
   equivalent standalone maintenance command:

   ```sh
   "$HOME/Applications/CMUX Maestro Preview.app/Contents/MacOS/CMUX Maestro Preview" \
     --install-copilot-integration --copilot-executable "$(command -v copilot)"
   ```

   Same installer and production-identity checks. Opens no setup windows,
   changes no accounts, restarts no existing conversations.
   Normal app startup still performs no installation.
   Production preview builds disable coverage instrumentation. Setup leaves no
   `default.profraw` in caller's worktree. Test coverage stays enabled.
3. If not already enabled, select **Maestro Sidebar** in CMUX's **Sidebar
   Extensions** browser. Installation does not change host grants or selection.
4. Leave existing Copilot chats running. New sessions load installed
   configuration. Already-running sessions may retain cached hooks. Installation
   neither restarts nor adopts them. Fresh-session acceptance is separate from
   on-disk installation. Setup also
   installs bundled `/cmux-maestro-native:cmux-maestro-orchestrate`
   and `/cmux-maestro-native:maestro-icon`
   skills and local controller. Only newly Maestro-spawned managed
   sessions get native messaging bindings automatically.
5. For optional messaging guide, open Maestro **Settings > CLI Integration**.
   Copy global install command. Run it yourself as described in
   [CLI guide, enable, and uninstall](cli-guide-and-uninstall.md#cli-integration-install-the-global-guide).
   Runtime setup never installs global guide.

### Installer process and cancellation

See [installer process and cancellation](setup-and-integration/installer-process-and-cancellation.md).

### Plugin and observer hook

See [plugin and observer hook](setup-and-integration/plugin-and-observer-hook.md).

### Legacy migration and disable preservation

See [legacy migration and disable preservation](setup-and-integration/legacy-migration-and-disable-preservation.md).

### Status, failures and messaging configuration

See [status, failures and messaging configuration](setup-and-integration/status-failures-and-messaging-configuration.md).
