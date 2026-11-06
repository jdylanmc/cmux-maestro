# Setup and Copilot integration

What install does to Copilot, what it refuses, how disable and rollback behave. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

<a id="cmux-maestro"></a>

## Sidebar overview

A compiled macOS CMUX sidebar shows Copilot sessions and explicit
terminal-backed orchestration hierarchies. It reads locally, with no companion
daemon, watcher, loopback server, XPC service, raw CMUX socket or session-start
ritual. The separate interpreted Maestro project is untouched and is not a
dependency. Regression evidence, live acceptance scope, intentional differences
and remaining limits are in the [behavioral parity matrix](../behavioral-parity.md).

Sidebar path labels for workspace/project paths, surface directories, hover and
pinned details use the real account home (`~` or `~/…`). Formatting normalizes
separators and dot components lexically. It never probes the filesystem or
resolves symlinks. Outside paths stay absolute, missing/denied states stay
explicit, and ownership/navigation values are unchanged. If account-home
resolution fails, an absolute label explains it.

**Surface directory** is the directory CMUX reports for that exact surface, not
an independently verified agent process or last-tool working directory.
**Parent surface directory** is parent placement only, not a windowless child's
own directory. Help and accessibility keep this source qualification and the
absence of a report timestamp. Fresh session observation does not establish
directory-report age. Assigned/last-verified Git worktree labels are separate
evidence, never directory fallbacks. Retained original sessions do not borrow
replacements' paths.

At pinned SDK/host revision `ae7fbce99f98c98df5ccf915e548dd080d33cfa8`,
[`CmuxSidebarSurface.workingDirectory`](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarSurface.swift)
is optional and `workspacePaths` filters it. The
[sidebar producer](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/ContentView.swift#L12736-L12748)
uses `reportedPanelDirectory(panelId:)`, whose
[implementation](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/Workspace%2BSidebarDirectories.swift#L48-L70)
normalizes the panel report and applies remote trust gating without the
separate `effectivePanelDirectory` local/requested-directory fallback. This is
source-level provenance only, not installed-host acceptance of #77 or
runtime-directory collection.

## One-time setup

1. Use the [alpha installer](install/local-preview.md). Normal install and
   update include Copilot automatically, with no separate setup action. The
   installer uses the configured `PATH` or an explicit trusted
   `--copilot-executable /absolute/path/to/copilot`, and assumes no shell
   startup files or machine-specific provider cache paths.
2. The containing app keeps **Enable Copilot Integration** and
   **Choose Copilot…** for explicitly requested maintenance; they are not
   normal-install prerequisites. The production app also keeps the equivalent
   standalone maintenance command:

   ```sh
   "$HOME/Applications/CMUX Maestro Preview.app/Contents/MacOS/CMUX Maestro Preview" \
     --install-copilot-integration --copilot-executable "$(command -v copilot)"
   ```

   It runs the same installer and production-identity checks, opens no setup
   windows, changes no accounts and restarts no existing conversations. Normal
   app startup still installs nothing. Production preview builds disable
   coverage instrumentation, so setup leaves no `default.profraw` in the
   caller's worktree. Test coverage stays enabled.
3. If not already enabled, select **Maestro Sidebar** in CMUX's **Sidebar Extensions**
   browser. Installation does not change host grants or selection.
4. Leave existing Copilot chats running. New sessions load the installed
   configuration, and already-running sessions may keep cached hooks;
   installation neither restarts nor adopts them. Fresh-session acceptance is
   separate from on-disk installation. Setup also installs the bundled
   `/cmux-maestro-native:cmux-maestro-orchestrate` and
   `/cmux-maestro-native:maestro-icon` skills and the local controller. Only
   newly Maestro-spawned managed sessions get native messaging bindings
   automatically.
5. For the optional messaging guide, open Maestro **Settings > CLI
   Integration**, copy the global install command and run it yourself
   ([CLI guide, enable, and uninstall](cli-guide-and-uninstall.md#cli-integration-install-the-global-guide)).
   Runtime setup never installs the global guide.

### Installer process and cancellation

[Installer process and cancellation](setup-and-integration/installer-process-and-cancellation.md)

### Plugin and observer hook

[Plugin and observer hook](setup-and-integration/plugin-and-observer-hook.md)

### Legacy migration and disable preservation

[Legacy migration and disable preservation](setup-and-integration/legacy-migration-and-disable-preservation.md)

### Status, failures and messaging configuration

[Status, failures and messaging configuration](setup-and-integration/status-failures-and-messaging-configuration.md)
