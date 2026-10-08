import SwiftUI

@MainActor
struct CLIIntegrationSettingsView: View {
    @State private var model: CLIIntegrationGuideModel
    private let copyCommand: () -> Bool

    init(
        model: CLIIntegrationGuideModel? = nil,
        copyCommand: @escaping () -> Bool = { CLIIntegrationGuide.copyInstallCommand() }
    ) {
        _model = State(initialValue: model ?? CLIIntegrationGuideModel())
        self.copyCommand = copyCommand
    }

    var body: some View {
        Form {
            Section("Maestro CLI guide content") {
                Text("Add the global /maestro skill to GitHub Copilot for peer discovery, sending messages, and replies.")
                if model.isChecking {
                    Text("Checking guide content...")
                        .accessibilityIdentifier("cli-integration-checking")
                } else if let result = model.result {
                    switch result {
                    case .referenceUnavailable:
                        Text("Build reference unavailable. Guide content could not be compared. Nothing was changed.")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("cli-integration-reference-error")
                    case .checked(let observations):
                        ForEach(observations) { observation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(observation.content.title)
                                    .foregroundStyle(observation.content == .matching ? Color.green : Color.primary)
                                Text(observation.displayPath)
                                    .textSelection(.enabled)
                                Text(observation.content.detail)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("cli-integration-status-" + observation.relativePath)
                        }
                    }
                } else {
                    Text("Guide content not checked.")
                }
                Button("Re-check") { Task { await model.recheck() } }
                    .disabled(model.isChecking)
                    .help("Read global guide content again without changing any files.")
                    .accessibilityIdentifier("cli-integration-recheck")
                Text("Global file observations only. Project guides and session-loaded content are not checked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Install / Update manually") {
                Text("Copy this command, paste it into your own terminal, and run it. Review the installer's interactive confirmation.")
                    .foregroundStyle(.secondary)
                Text(CLIIntegrationGuide.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cli-integration-install-command")
                Button("Copy install command") {
                    model.copyCommand(using: copyCommand)
                }
                .accessibilityIdentifier("cli-integration-copy-command")
                .accessibilityValue(model.copyNotice ?? String(localized: "Not copied"))
                if let notice = model.copyNotice {
                    Text(notice).font(.caption)
                        .accessibilityIdentifier("cli-integration-copy-feedback")
                }
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
        .task { if model.result == nil { await model.recheck() } }
    }
}
