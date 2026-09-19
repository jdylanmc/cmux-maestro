import Darwin
import Foundation
import SwiftUI

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
                        Picker("Launch agents with subscription:", selection: $account) {
                            Text("Use Copilot default").tag("")
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
                        Text("Uses the selected GitHub account’s Copilot subscription. Git identity and the active gh account are unchanged. Account names are shown; plan tiers are not inferred.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Worker model:", text: $model, prompt: Text("Use Copilot default"))
                            .accessibilityIdentifier("worker-model-setting")
                        Text("Only new workers are affected. Credentials stay in the keychain and are resolved at launch. A missing pinned account blocks launch rather than using another account.")
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
