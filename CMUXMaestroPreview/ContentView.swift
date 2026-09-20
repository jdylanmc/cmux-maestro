import SwiftUI
import AppKit

struct ContentView: View {
    @State private var executable: URL?
    @State private var busy = false
    @State private var result: CopilotSetupResult?
    @State private var pendingAction: CopilotSetupAction?
    @State private var setupTask: Task<Void, Never>?
    @State private var nativeSetup: Bool?
    @State private var nativeNotice: String?

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
                    .accessibilityLabel("Choose Copilot executable")
                    .accessibilityIdentifier("copilot-setup-choose-executable")
            }

            Text("Enable installs the cmux-maestro-native plugin, its orchestration skill, and the local controller command. Existing plugins and settings are preserved. Choose only a Copilot executable you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Enable Copilot Integration") { pendingAction = .install }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Enable Copilot Integration")
                    .accessibilityIdentifier("copilot-setup-enable")
                Button("Uninstall Native Plugin…") { pendingAction = .uninstall }
                    .accessibilityLabel("Uninstall Native Plugin")
                    .accessibilityIdentifier("copilot-setup-uninstall")
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)

            if busy {
                Button("Cancel Setup") { setupTask?.cancel() }
                    .accessibilityLabel("Cancel running Copilot setup")
                    .accessibilityIdentifier("copilot-setup-cancel-running")
            }

            if let result {
                Text(result.message)
                    .font(.callout)
                    .accessibilityIdentifier("copilot-setup-result")
            }

            Divider()
            HStack {
                Button("Enable Native Messaging…") { nativeSetup = true }
                    .disabled(!NativeSigningReadiness.current)
                    .accessibilityLabel("Enable Native Messaging")
                    .accessibilityIdentifier("native-setup-enable")
                Button("Disable Native Messaging…") { nativeSetup = false }
                    .accessibilityLabel("Disable Native Messaging")
                    .accessibilityIdentifier("native-setup-disable")
            }.disabled(busy)
            if !NativeSigningReadiness.current {
                Text(NativeSigningReadiness.unsupported).font(.caption).foregroundStyle(.secondary)
            }
            Text("Optional: installs an inert user extension for newly authorized Maestro workers only. Does not restart, adopt, or configure existing sessions. No permission callbacks or alternate Copilot home.")
                .font(.caption).foregroundStyle(.secondary)
            if let nativeNotice {
                Text(nativeNotice).font(.caption)
                    .accessibilityIdentifier("native-setup-result")
            }
            SettingsLink {
                Label("Agent launch settings…", systemImage: "gearshape")
            }
            .accessibilityLabel("Agent launch settings")
            .accessibilityIdentifier("agent-launch-settings")
            Text("Next: enable CMUX Maestro Preview in CMUX’s Sidebar Extensions browser and select it. Restart or resume existing Copilot CLI sessions once to load the plugin and orchestration skill; future sessions work normally. Never restart sessions automatically.")
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
                .accessibilityLabel(action == .install ? "Confirm installation of Native Plugin" : "Confirm removal of Native Plugin")
                .accessibilityIdentifier(action == .install ? "copilot-setup-confirm-install" : "copilot-setup-confirm-uninstall")
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
                .accessibilityLabel("Cancel Copilot plugin changes")
                .accessibilityIdentifier("copilot-setup-cancel-confirmation")
        } message: {
            Text("This explicitly runs the selected Copilot CLI to change only cmux-maestro-native. No CLI sessions will be restarted and no legacy integration will be removed.")
        }
        .alert("Change native messaging setup?", isPresented: Binding(
            get: { nativeSetup != nil }, set: { if !$0 { nativeSetup = nil } }
        )) {
            Button("Confirm") {
                do {
                    try NativeMessagingSetup.setEnabled(nativeSetup == true)
                    nativeNotice = "Setup updated for future loads. Existing sessions were not changed."
                } catch {
                    nativeNotice = "Setup unavailable. Enable the base integration first; only the standard Copilot home is supported."
                }
                nativeSetup = nil
            }
            .accessibilityLabel(nativeSetup == true ? "Confirm enabling Native Messaging" : "Confirm disabling Native Messaging")
            .accessibilityIdentifier(nativeSetup == true ? "native-setup-confirm-enable" : "native-setup-confirm-disable")
            Button("Cancel", role: .cancel) { nativeSetup = nil }
                .accessibilityLabel("Cancel Native Messaging setup changes")
                .accessibilityIdentifier("native-setup-cancel-confirmation")
        } message: {
            Text("Enable writes only Maestro’s loader in ~/.copilot/extensions. A human must first authorize the displayed run policy; workers in that run with the exact same policy can reuse that authorization with a one-time launch ticket for each worker. Disable prevents future authorization reuse and leaves the loader inert for future loads, without terminating existing sessions.")
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
