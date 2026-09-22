import SwiftUI
import AppKit

struct ContentView: View {
    @State private var executable: URL?
    @State private var busy = false
    @State private var result: CopilotSetupResult?
    @State private var pendingAction: CopilotSetupAction?
    @State private var setupTask: Task<Void, Never>?

    var body: some View {
        if CopilotSetupAccess.currentAppAllowsChanges {
            setupContents
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label("Maestro validation copy", systemImage: "testtube.2")
                    .font(.headline)
                Text(CopilotSetupResult.validationOnly.message)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 380, alignment: .leading)
        }
    }

    private var setupContents: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("CMUX Maestro Preview", systemImage: "sidebar.left")
                .font(.title2.weight(.semibold))

            Text("One-time Copilot integration")
                .font(.headline)
            Text("The native sidebar reads validated session and orchestration metadata locally. Terminal-backed control stays outside the sandboxed extension; the sidebar can only observe and use CMUX's typed Focus action.")
                .foregroundStyle(.secondary)

            HStack {
                Text(executable == nil ? "Copilot CLI: configured PATH" : "Copilot CLI: selected executable")
                    .font(.callout)
                Spacer()
                Button("Choose Copilot…", action: chooseExecutable)
                    .disabled(busy)
            }

            Text("Enable installs the cmux-maestro-native lifecycle and icon plugin, the local controller, and a native messaging loader under ~/.copilot/extensions/maestro. The loader is inert outside newly Maestro-launched participating sessions. Install the optional global /maestro guide separately from Settings > CLI Integration. Existing unrelated plugins and settings are preserved. Choose only a Copilot executable you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Enable Copilot Integration") { pendingAction = .install }
                    .buttonStyle(.borderedProminent)
                Button("Uninstall Native Plugin…") { pendingAction = .uninstall }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)

            if busy {
                Button("Cancel Setup") { setupTask?.cancel() }
            }

            if let result {
                Text(result.message)
                    .font(.callout)
                    .accessibilityIdentifier("copilot-setup-result")
            }

            Divider()
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            Text("Next: configure a pinned account and model in Agent launch settings. New Maestro-launched sessions get fire-and-forget messaging; existing or unmanaged sessions are not adopted. Messaging never changes focus or human input and does not guarantee delivery. The sidebar is optional for messaging.")
                .font(.callout)
            Text("Keep this app at its installed location. If you move or replace it, enable the integration again to refresh the bundled helper path. Uses the standard ~/.copilot/session-state location only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 580, alignment: .leading)
        .confirmationDialog("Allow Copilot plugin changes?", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible) {
            if let action = pendingAction {
                Button(action == .install ? "Install Native Plugin" : "Uninstall Native Plugin",
                       role: action == .uninstall ? .destructive : nil) {
                    pendingAction = nil
                    perform(action)
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("This explicitly runs the selected Copilot CLI for cmux-maestro-native and installs or removes its native messaging entry point. No CLI sessions will be restarted and no legacy integration will be removed.")
        }
    }

    private func chooseExecutable() {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the trusted Copilot CLI executable to use for plugin installation."
        if panel.runModal() == .OK { executable = panel.url }
    }

    private func perform(_ action: CopilotSetupAction) {
        guard CopilotSetupAccess.currentAppAllowsChanges else {
            result = .validationOnly
            return
        }
        busy = true
        result = nil
        setupTask = Task {
            defer {
                busy = false
                setupTask = nil
            }
            guard let root = try? CopilotPaths.integrationRoot() else {
                result = .unavailable
                return
            }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook")
            guard let controller = Bundle.main.url(
                forResource: "cmux-maestro-orchestrator", withExtension: "py"
            ), let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
                result = .unavailable
                return
            }
            result = await CopilotSetup().perform(action, selected: executable,
                path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                root: root, helper: helper, controller: controller, skill: skill)
        }
    }
}

#Preview {
    ContentView()
}
