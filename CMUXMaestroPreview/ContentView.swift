import SwiftUI
import AppKit

struct ContentView: View {
    @State private var executable: URL?
    @State private var busy = false
    @State private var result: CopilotSetupResult?
    @State private var pendingAction: CopilotSetupAction?
    @State private var setupTask: Task<Void, Never>?
    @State private var registrationHealth: IntegrationRegistrationHealth?
    @State private var checkingRegistration = false

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

            Text("Enable installs the hookless cmux-maestro-native lifecycle and icon plugin, ~/.copilot/hooks/cmux-maestro-observer.json, the local controller and the loader under ~/.copilot/extensions/maestro. Private observer-registration.json provenance and .observer-setup.lock live in the app's Copilot support directory. The loader is inert outside newly Maestro-launched participating sessions. Maestro does not write global settings; the official CLI may normalize its plugin settings. Choose only a Copilot executable you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                Text(registrationHealth?.message ?? "Observer registration has not been checked.")
                    .font(.callout)
                    .accessibilityIdentifier("copilot-registration-status")
                Spacer()
                Button("Check Registration", action: checkRegistration)
                    .disabled(busy || checkingRegistration)
            }

            HStack {
                Button("Enable Copilot Integration") { pendingAction = .install }
                    .buttonStyle(.borderedProminent)
                Button("Remove Copilot Integration…") { pendingAction = .uninstall }
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
            Text("Next: choose an initial coordinator account and explicit model in Agent launch settings, then use Maestro’s launch-coordinator entry. Managed children inherit their invoking session’s account. Existing conversations are not adopted. Messaging preserves focus and human input and does not guarantee delivery; the sidebar is optional.")
                .font(.callout)
            Text("Keep this app at its installed location. If you move or replace it, enable the integration again to refresh the bundled helper path. Uses the standard ~/.copilot/session-state location only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 580, alignment: .leading)
        .confirmationDialog("Allow Copilot integration changes?", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible) {
            if let action = pendingAction {
                Button(action == .install ? "Enable Integration" : "Remove Integration",
                       role: action == .uninstall ? .destructive : nil) {
                    pendingAction = nil
                    perform(action)
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("This runs bounded metadata checks and plugin commands through the selected Copilot CLI. Enable stages only a disabled owned hook file, replaces recognized legacy observer declarations, then verifies before activation. Maestro never clears disable keys. The CLI may rewrite settings without value changes or add an empty plugin map; other changed values stop setup. Unresolvable disables, foreign content and unsafe paths also stop setup. Remove deletes only recognized owned observer registration and its native messaging entry point. Partial changes are reported. Existing CLI sessions and other integrations are not restarted, adopted or removed.")
        }
    }

    private func checkRegistration() {
        guard CopilotSetupAccess.currentAppAllowsChanges, !checkingRegistration else { return }
        checkingRegistration = true
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook")
        Task {
            defer { checkingRegistration = false }
            do {
                registrationHealth = try await CopilotSetupFileWork.run {
                    let home = try CopilotPaths.realUserHome()
                    let root = try CopilotPaths.integrationRoot()
                    return CopilotObserverRegistration(home: home, root: root, helper: helper).health()
                }
            } catch { registrationHealth = .unavailable }
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
            checkRegistration()
        }
    }
}

#Preview {
    ContentView()
}
