import Foundation
import Testing
import UserNotifications
import CoreGraphics
import ImageIO
import Intents
@testable import CMUXMaestroPreview

@MainActor
struct MaestroNotificationTests {
    @Test func bundledReadAcceptsRootOwnerButCustomReadDoesNot() throws {
        let file = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
        let directory = try CopilotFileAccess.openDirectory(file.deletingLastPathComponent())
        defer { close(directory) }
        #expect(try CopilotFileAccess.statEntry(at: directory, name: file.lastPathComponent).uid == 0)
        let data = try CopilotFileAccess.readBundledResource(file, maximum: 10 * 1024 * 1024)
        #expect(!data.isEmpty)
        #expect(throws: (any Error).self) { try MaestroNotificationAssets.read(file, maximum: 10 * 1024 * 1024) }
    }

    @Test func bundledAndCustomReadsRejectUnsafeModesAndSymlinks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/notification-pet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pet.png")
        try Data("synthetic".utf8).write(to: file)
        for mode in [0o622, 0o664, 0o666] {
            #expect(chmod(file.path, mode_t(mode)) == 0)
            #expect(throws: (any Error).self) { try CopilotFileAccess.readBundledResource(file, maximum: 1024) }
            #expect(throws: (any Error).self) { try MaestroNotificationAssets.read(file, maximum: 1024) }
        }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try CopilotFileAccess.readBundledResource(file, maximum: 1024) == Data("synthetic".utf8))
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try CopilotFileAccess.readBundledResource(link, maximum: 1024) }
        #expect(throws: (any Error).self) { try MaestroNotificationAssets.read(link, maximum: 1024) }
    }

    @Test func guiControllerPathUsesRegisteredHostAndPreservesBinding() {
        let controller = MaestroNotificationController(
            executable: URL(fileURLWithPath: "/synthetic/controller"),
            hostExecutable: URL(fileURLWithPath: "/synthetic/cmux.app/Contents/Resources/bin/cmux")
        )
        let environment = controller.environment(inherited: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SESSION_ID": "synthetic"])
        #expect(environment["PATH"] == "/synthetic/cmux.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["SESSION_ID"] == "synthetic")
    }

    @Test func deniedNeverPromptsOrSubmits() async throws {
        let center = NotificationCenterDouble(status: .denied)
        let request = UNNotificationRequest(identifier: "synthetic", content: UNMutableNotificationContent(), trigger: nil)
        await #expect(throws: MaestroNotificationFailure.unauthorized) {
            try await MaestroNotificationDelivery(center: center).submit(request)
        }
        #expect(center.prompts == 0)
        #expect(center.requests.isEmpty)
    }

    @Test func permissionAndFinalIdentityGatePrecedeSubmission() async throws {
        let center = NotificationCenterDouble(status: .notDetermined)
        let request = UNNotificationRequest(identifier: "synthetic", content: UNMutableNotificationContent(), trigger: nil)
        await #expect(throws: MaestroNotificationFailure.muted) {
            try await MaestroNotificationDelivery(center: center).submit(request) {
                #expect(center.prompts == 1)
                #expect(center.requests.isEmpty)
                throw MaestroNotificationFailure.muted
            }
        }
        #expect(center.requests.isEmpty)
        try await MaestroNotificationDelivery(center: center).submit(request)
        #expect(center.prompts == 1)
        #expect(center.requests.count == 1)
    }

    @Test func formattingUsesSystemPriorityUniqueIDsAndExactSessionThread() throws {
        let session = UUID()
        let admission = MaestroNotificationAdmission(
            target: .init(nodeId: UUID(), sessionId: session, workspaceId: UUID(), surfaceId: UUID(), generation: 2),
            clickToken: String(repeating: "a", count: 64), name: "Synthetic"
        )
        let normal = MaestroNotificationContent(message: String(repeating: "x", count: 141), urgent: false)
            .request(admission: admission)
        let urgent = MaestroNotificationContent(message: "Choose one", urgent: true).request(admission: admission)
        #expect(normal.content.title.isEmpty)
        #expect(normal.content.body == String(repeating: "x", count: 139) + "…")
        #expect(normal.content.subtitle.isEmpty)
        #expect(normal.content.sound == nil)
        #expect(urgent.content.sound != nil)
        #expect(normal.content.interruptionLevel == .active && urgent.content.interruptionLevel == .active)
        #expect(urgent.content.subtitle.isEmpty)
        #expect(normal.content.threadIdentifier == session.uuidString.lowercased())
        #expect(normal.identifier != urgent.identifier)
        #expect(normal.content.attachments.isEmpty)
        #expect(normal.content.userInfo["maestroClickToken"] as? String == admission.clickToken)
        #expect(MaestroNotificationContent.text("a\u{202e}b\u{0007}", limit: 140) == "ab")
    }

    @Test func communicationUsesNeutralTitleExactAccountAndIncomingOnly() throws {
        let session = UUID()
        let admission = MaestroNotificationAdmission(
            target: .init(nodeId: UUID(), sessionId: session, workspaceId: UUID(), surfaceId: UUID(), generation: 2),
            clickToken: String(repeating: "b", count: 64), name: "Rejected filename.md"
        )
        let renderer = try MaestroNotificationAvatar(catalog: .shared.get())
        let avatar = try renderer.png(choice: .init(glyph: "md-account_music_outline", color: .teal))
        let interaction = MaestroNotificationCommunication().interaction(
            admission: admission, message: "Choose\u{0000} one", avatar: avatar, id: "synthetic-request"
        )
        let intent = try #require(interaction.intent as? INSendMessageIntent)
        #expect(interaction.direction == .incoming)
        #expect(interaction.identifier == "synthetic-request")
        #expect(intent.sender?.displayName == "Maestro agent")
        #expect(intent.sender?.contactIdentifier == nil)
        #expect(intent.sender?.suggestionType == INPersonSuggestionType.none)
        #expect(intent.sender?.personHandle?.value == "maestro-agent:\(session.uuidString.lowercased())")
        #expect(intent.conversationIdentifier == "maestro-session:\(session.uuidString.lowercased())")
        #expect(intent.recipients == nil)
        #expect(intent.content == "Choose one")
        #expect(intent.sender?.image != nil)
    }

    @Test func avatarUsesBundledGlyphColorAndRefusesUnknownGlyph() throws {
        let renderer = try MaestroNotificationAvatar(catalog: .shared.get())
        let teal = try renderer.png(choice: .init(glyph: "md-account_music_outline", color: .teal))
        let blue = try renderer.png(choice: .init(glyph: "md-account_music_outline", color: .blue))
        let robot = try renderer.png(choice: .init(glyph: "md-robot", color: .teal))
        #expect(teal != blue && teal != robot)
        let source = try #require(CGImageSourceCreateWithData(teal as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 256 && image.height == 256)
        #expect(teal.count <= 262_144)
        #expect(throws: (any Error).self) {
            try renderer.png(choice: .init(glyph: "../../foreign-font", color: .teal))
        }
    }

    @Test func humanIconOverrideAndResetWinWithoutReadingSessionContent() throws {
        let home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/notification-appearance-\(UUID().uuidString)")
        let root = MaestroNotificationAssets.sidebarRoot(home: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = UUID()
        let agent = CMUXMaestroPreview.CopilotSessionAppearance(
            sessionID: session, iconId: "md-account_music_outline", iconColor: "teal"
        )
        let reader = MaestroNotificationAppearance(home: home)
        #expect(try reader.choice(session: session, agent: agent) == .init(glyph: "md-account_music_outline", color: .teal))
        var settings = CMUXMaestroPreview.SidebarIconSettings()
        settings.overrides[CMUXMaestroPreview.SidebarIconTarget.session(session).key] =
            .custom(.init(glyph: "md-duck", color: .custom(.init(red: 18, green: 171, blue: 239))))
        let file = root.appendingPathComponent("sidebar-icons.json")
        try JSONEncoder().encode(settings).write(to: file)
        #expect(try reader.choice(session: session, agent: agent).glyph == "md-duck")
        #expect(try reader.choice(session: session, agent: agent).color.rawValue == "#12ABEF")
        #expect(try reader.choice(session: UUID(), agent: nil).glyph == "md-robot")
        settings.overrides[CMUXMaestroPreview.SidebarIconTarget.session(session).key] = .standard
        try JSONEncoder().encode(settings).write(to: file)
        #expect(try reader.choice(session: session, agent: agent) == .init(glyph: "md-robot", color: .theme))
        #expect(throws: (any Error).self) { try reader.choice(session: UUID(), agent: agent) }
        try Data("invalid preferences".utf8).write(to: file)
        #expect(throws: (any Error).self) { try reader.choice(session: session, agent: agent) }
    }

    @Test func donationPreparationIsPermissionAndIdentityGatedAndRevalidated() async throws {
        let center = NotificationCenterDouble(status: .denied)
        let request = UNNotificationRequest(identifier: "synthetic", content: UNMutableNotificationContent(), trigger: nil)
        var preparationCalls = 0
        let prepare: (UNNotificationRequest) async throws -> UNNotificationRequest = {
            preparationCalls += 1
            return $0
        }
        await #expect(throws: MaestroNotificationFailure.unauthorized) {
            try await MaestroNotificationDelivery(center: center).submit(request, prepare: prepare)
        }
        #expect(preparationCalls == 0)
        center.status = .authorized
        await #expect(throws: MaestroNotificationFailure.muted) {
            try await MaestroNotificationDelivery(center: center).submit(request, prepare: prepare) {
                throw MaestroNotificationFailure.muted
            }
        }
        #expect(preparationCalls == 0)
        var checks = 0
        await #expect(throws: MaestroNotificationFailure.unavailable) {
            try await MaestroNotificationDelivery(center: center).submit(request, prepare: prepare) {
                checks += 1
                if checks == 2 { throw MaestroNotificationFailure.unavailable }
            }
        }
        #expect(preparationCalls == 1 && checks == 2)
        #expect(center.requests.isEmpty)
    }

    @Test func unsignedValidationCannotDonateCommunication() async throws {
        let admission = MaestroNotificationAdmission(
            target: .init(nodeId: UUID(), sessionId: UUID(), workspaceId: UUID(), surfaceId: UUID(), generation: 1),
            clickToken: String(repeating: "c", count: 64), name: "Synthetic"
        )
        let communication = MaestroNotificationCommunication()
        let request = MaestroNotificationContent(message: "Synthetic", urgent: false).request(admission: admission)
        let interaction = communication.interaction(admission: admission, message: "Synthetic", avatar: Data(), id: request.identifier)
        await #expect(throws: MaestroNotificationFailure.unavailable) {
            try await communication.prepare(request, interaction: interaction)
        }
    }

    @Test func authoredAppearanceReadNeedsNoSessionDirectoryAndRejectsMismatchedIdentity() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/notification-authored-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CMUXMaestroPreview.CopilotSessionReader(
            bindingDirectory: root, sessionStateRoot: root.appendingPathComponent("absent-sessions")
        )
        let session = UUID()
        #expect(try await reader.sessionAppearance(for: session) == nil)
        let appearance = CMUXMaestroPreview.CopilotSessionAppearance(
            sessionID: session, iconId: "md-account_music_outline", iconColor: "teal"
        )
        let file = root.appendingPathComponent("appearance-\(session.uuidString.lowercased()).json")
        try JSONEncoder().encode(appearance).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try await reader.sessionAppearance(for: session) == appearance)
        let other = CMUXMaestroPreview.CopilotSessionAppearance(sessionID: UUID(), iconId: "md-robot")
        try JSONEncoder().encode(other).write(to: file)
        await #expect(throws: (any Error).self) { try await reader.sessionAppearance(for: session) }
    }
}

@MainActor
private final class NotificationCenterDouble: MaestroNotificationCenter {
    var status: UNAuthorizationStatus
    var prompts = 0
    var requests: [UNNotificationRequest] = []
    init(status: UNAuthorizationStatus) { self.status = status }
    func authorization() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { prompts += 1; status = .authorized; return true }
    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
}
