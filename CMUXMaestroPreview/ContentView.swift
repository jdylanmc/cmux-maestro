import SwiftUI
import AppKit

struct ContentView: View {
    @State private var executable: URL?
    @State private var busy = false
    @State private var result: CopilotSetupResult?
    @State private var pendingAction: CopilotSetupAction?
    @State private var setupTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("CMUX Maestro Preview", systemImage: "sidebar.left")
                .font(.title2.weight(.semibold))

            Text("One-time Copilot integration")
                .font(.headline)
            Text("The native sidebar reads validated session identities and durable event metadata locally, then displays sanitized agent trees. It cannot prompt, stop, or control Copilot. This app only installs the integration; it does not observe sessions.")
                .foregroundStyle(.secondary)

            HStack {
                Text(executable == nil ? "Copilot CLI: configured PATH" : "Copilot CLI: selected executable")
                    .font(.callout)
                Spacer()
                Button("Choose Copilot…", action: chooseExecutable)
                    .disabled(busy)
            }

            Text("Enable installs only the cmux-maestro-native plugin. Existing plugins and settings are preserved. Choose only a Copilot executable you trust.")
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
            Text("Next: enable CMUX Maestro Preview in CMUX’s Sidebar Extensions browser and select it. Restart or resume existing Copilot CLI sessions once to load the new plugin; future sessions work normally. Never restart sessions automatically.")
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
            Text("This explicitly runs the selected Copilot CLI to change only cmux-maestro-native. No CLI sessions will be restarted and no legacy integration will be removed.")
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the trusted Copilot CLI executable to use for plugin installation."
        if panel.runModal() == .OK { executable = panel.url }
    }

    private func perform(_ action: CopilotSetupAction) {
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
            result = await CopilotSetup().perform(action, selected: executable,
                path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                root: root, helper: helper)
        }
    }
}

#Preview {
    ContentView()
}
