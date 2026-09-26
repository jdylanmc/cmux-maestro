import Foundation
import Testing
import AppKit
import SwiftUI
@testable import CMUXMaestroPreview

struct WorkerLaunchSettingsTests {
    @Test(SidebarAppKitTestScope()) @MainActor func cliGuideCopiesExactUserRunGlobalCommand() throws {
        let expected = "npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy"
        let pasteboard = NSPasteboard(name: .init("maestro-settings-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(CLIIntegrationGuide.installCommand == expected)
        #expect(CLIIntegrationGuide.copyInstallCommand(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(!expected.contains("--yes"))
        let view = NSHostingView(rootView: CLIIntegrationSettingsView())
        #expect(view.fittingSize.width == 600)
        #expect(view.fittingSize.height == 350)
        let settings = NSHostingView(rootView: MaestroSettingsView())
        #expect(settings.fittingSize.width == 640)
        #expect(settings.fittingSize.height == 450)
    }

    @Test func defaultSettingsSceneExposesGuideWithoutExecutingInstallation() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: repository.appendingPathComponent(
            "CMUXMaestroPreview/CMUXMaestroPreviewApp.swift"), encoding: .utf8)
        #expect(app.contains("Settings {\n            MaestroSettingsView()\n        }"))
        #expect(app.components(separatedBy: "Settings {").count == 2)
        let settings = try String(contentsOf: repository.appendingPathComponent(
            "CMUXMaestroPreview/Integration/WorkerLaunchSettings.swift"), encoding: .utf8)
        let guide = try #require(settings.components(separatedBy: "nonisolated struct WorkerLaunchSettings:").first)
        #expect(guide.contains("WorkerLaunchSettingsView()"))
        #expect(guide.contains("CLIIntegrationSettingsView()"))
        #expect(guide.contains(#"Label("CLI Integration", systemImage: "terminal")"#))
        #expect(guide.contains("Text(CLIIntegrationGuide.installCommand)"))
        #expect(guide.contains(#"Button("Copy install command")"#))
        #expect(guide.contains("CLIIntegrationGuide.copyInstallCommand()"))
        for forbidden in [
            "Process(", "NSWorkspace", "CopilotSetup()", ".task", ".onAppear", "--yes",
            ".copilot/skills", "FileManager", "Data(contentsOf:", "URLSession",
            "Up to date", "Matches this build", ".orange"
        ] {
            #expect(!guide.contains(forbidden))
        }
    }

    @Test func defaultsAreUnpinnedAndStoredPreferencesContainNoCredential() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/worker-launch-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try WorkerLaunchSettings.load(from: root) == .init())
        let chosen = WorkerLaunchSettings(copilotAccount: "work-user", model: "example-large-model")
        try chosen.save(to: root)
        #expect(try WorkerLaunchSettings.load(from: root) == chosen)
        let file = root.appendingPathComponent("worker-settings.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "copilotAccount", "model"])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func invalidPreferencesCannotReplacePreviousSelection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/worker-launch-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = WorkerLaunchSettings(copilotAccount: "work-user", model: nil)
        try original.save(to: root)
        #expect(throws: (any Error).self) {
            try WorkerLaunchSettings(copilotAccount: "--show-token", model: nil).save(to: root)
        }
        #expect(try WorkerLaunchSettings.load(from: root) == original)
        try Data(#"{"version":1,"token":"not-a-supported-setting"}"#.utf8)
            .write(to: root.appendingPathComponent("worker-settings.json"))
        #expect(throws: (any Error).self) { try WorkerLaunchSettings.load(from: root) }
    }
}
