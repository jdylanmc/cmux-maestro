import Darwin
import Foundation
import SwiftUI
import AppKit

struct MaestroSettingsView: View {
    var body: some View {
        TabView {
            WorkerLaunchSettingsView()
                .tabItem { Label("Agent launches", systemImage: "person.crop.circle") }
            CLIIntegrationSettingsView()
                .tabItem { Label("CLI Integration", systemImage: "terminal") }
        }
        .padding(20)
        .frame(width: 640, height: 450)
    }
}

enum CLIIntegrationGuide {
    static let installCommand = "npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy"

    static func copyInstallCommand(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(installCommand, forType: .string)
    }
}

struct CLIIntegrationSettingsView: View {
    @State private var notice: String?

    var body: some View {
        Form {
            Section("Install the Maestro CLI guide") {
                Text("Add the global /maestro skill to GitHub Copilot for peer discovery, sending messages, and replies.")
                Text("Copy this command, paste it into your own terminal, and run it. Review the installer's interactive confirmation.")
                    .foregroundStyle(.secondary)
                Text(CLIIntegrationGuide.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cli-integration-install-command")
                Button("Copy install command") {
                    notice = CLIIntegrationGuide.copyInstallCommand()
                        ? "Copied. Run the command in your terminal when ready."
                        : "Could not copy the command. Select and copy the text above."
                }
                .accessibilityIdentifier("cli-integration-copy-command")
                if let notice { Text(notice).font(.caption) }
            }
            Section("Runtime integration is separate") {
                Text("Use Enable Copilot Integration in the main Maestro window to install the runtime. The guide does not install or enable it, and messaging remains usable without the guide.")
                Text("Settings never runs this command or opens a terminal. No extra skill-activation grants are required. The repository command is available after the skill is merged to main; see the README for local-source development installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 350)
    }
}

nonisolated struct WorkerLaunchSettings: Codable, Equatable, Sendable {
    var version = 1
    var copilotAccount: String?
    var model: String?

    var isValid: Bool {
        version == 1
            && (copilotAccount.map { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$"#, options: .regularExpression) != nil } ?? true)
            && (model.map { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}$"#, options: .regularExpression) != nil } ?? true)
    }

    static func load(from root: URL) throws -> Self {
        let directory: Int32
        do {
            directory = try CopilotFileAccess.openDirectory(root, owner: getuid())
        } catch CopilotFileError.missing {
            return .init()
        }
        defer { close(directory) }
        let data: Data
        do {
            data = try CopilotFileAccess.readStableRegular(
                at: directory, filename: "worker-settings.json", owner: getuid(), maximum: 8192, permissions: 0o600
            )
        } catch CopilotFileError.missing {
            return .init()
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "copilotAccount", "model"]) else {
            throw SettingsError.invalid
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.isValid else { throw SettingsError.invalid }
        return value
    }

    func save(to root: URL) throws {
        guard isValid else { throw SettingsError.invalid }
        let directory = try HookFiles.privateDirectory(root)
        defer { close(directory) }
        try HookFiles.atomicWrite(JSONEncoder().encode(self), name: "worker-settings.json", directory: directory)
    }

    enum SettingsError: Error { case invalid, unavailable }
}

nonisolated struct WorkerSubscriptionAccount: Decodable, Identifiable, Sendable {
    let login: String
    let available: Bool
    var id: String { login }
}

nonisolated enum WorkerAccountDiscovery {
    private struct Response: Decodable { let ok: Bool; let accounts: [WorkerSubscriptionAccount] }

    static func accounts(controller: URL) async throws -> [WorkerSubscriptionAccount] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [controller.path, "accounts"]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    // The bundled command bounds both its subprocess time and metadata output.
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0, data.count <= 65_536 else {
                        throw WorkerLaunchSettings.SettingsError.unavailable
                    }
                    let response = try JSONDecoder().decode(Response.self, from: data)
                    guard response.ok, response.accounts.count <= 64 else {
                        throw WorkerLaunchSettings.SettingsError.unavailable
                    }
                    continuation.resume(returning: response.accounts)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct WorkerLaunchSettingsView: View {
    @State private var account = ""
    @State private var model = ""
    @State private var accounts: [WorkerSubscriptionAccount] = []
    @State private var busy = false
    @State private var notice: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if CopilotSetupAccess.currentAppAllowsChanges {
                Form {
                    Section("Agent launches") {
                        Picker("New coordinator subscription:", selection: $account) {
                            Text("Choose an initial account").tag("")
                            ForEach(accounts) { item in
                                Text(item.available ? item.login : "\(item.login) — unavailable")
                                    .tag(item.login)
                                    .disabled(!item.available)
                            }
                            if !account.isEmpty && !accounts.contains(where: { $0.login == account }) {
                                Text("\(account) — not currently available").tag(account)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("worker-subscription-picker")
                        HStack {
                            Button("Refresh accounts") { Task { await refreshAccounts() } }
                            if busy { ProgressView().controlSize(.small) }
                        }
                        .disabled(busy)
                        Text("Selects the initial account for a new managed coordinator. Its children inherit the invoking session’s verified account, not this setting. Git identity and the active gh account are unchanged; plan tiers are not inferred.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Model for new sessions:", text: $model, prompt: Text("Choose an explicit model"))
                            .accessibilityIdentifier("worker-model-setting")
                        Text("Existing sessions are unchanged. Credentials stay in the keychain and are resolved at launch. Missing account or model evidence blocks launch instead of selecting a fallback.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Save", action: save).buttonStyle(.borderedProminent).disabled(!loaded)
                        if let notice { Text(notice).font(.caption) }
                    }
                }
                .formStyle(.grouped)
                .task { await load() }
            } else {
                Text("Launch settings are available only in the installed Maestro app.")
                    .padding(24)
            }
        }
        .frame(width: 600, height: 350)
    }

    private func load() async {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return }
        do {
            let settings = try WorkerLaunchSettings.load(from: CopilotPaths.orchestrationRoot())
            account = settings.copilotAccount ?? ""
            model = settings.model ?? ""
            loaded = true
            await refreshAccounts()
        } catch {
            notice = "Launch settings could not be read. Nothing was changed."
        }
    }

    private func refreshAccounts() async {
        guard CopilotSetupAccess.currentAppAllowsChanges, !busy,
              let controller = Bundle.main.url(forResource: "cmux-maestro-orchestrator", withExtension: "py") else { return }
        busy = true
        defer { busy = false }
        do {
            accounts = try await WorkerAccountDiscovery.accounts(controller: controller)
            notice = accounts.isEmpty ? "No accounts found. Add an account with gh auth login." : nil
        } catch {
            notice = "Accounts could not be loaded. Check GitHub CLI authentication; the saved choice was not changed."
        }
    }

    private func save() {
        guard CopilotSetupAccess.currentAppAllowsChanges, loaded else { return }
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try WorkerLaunchSettings(
                copilotAccount: account.isEmpty ? nil : account,
                model: selectedModel.isEmpty ? nil : selectedModel
            ).save(to: CopilotPaths.orchestrationRoot())
            notice = "Saved for new workers. Existing sessions are unchanged."
        } catch {
            notice = "Could not save valid launch settings. The prior settings were preserved."
        }
    }
}
