import Foundation
import Testing
import UserNotifications
import CoreGraphics
import ImageIO
@testable import CMUXMaestroPreview

@MainActor
struct MaestroNotificationTests {
    @Test func unknownStateAddsNoUnsupportedWorkClaim() {
        let content = MaestroNotificationContent(name: "Synthetic", state: .unknown, message: "Choose one", urgent: false)
        #expect(content.subtitle.isEmpty)
    }

    @Test func bundledReadAcceptsRootOwnerButCustomReadDoesNot() throws {
        let file = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
        let directory = try CopilotFileAccess.openDirectory(file.deletingLastPathComponent())
        defer { close(directory) }
        #expect(try CopilotFileAccess.statEntry(at: directory, name: file.lastPathComponent).uid == 0)
        let data = try MaestroNotificationPet.readBundled(file, maximum: 10 * 1024 * 1024)
        #expect(!data.isEmpty)
        #expect(throws: (any Error).self) { try MaestroNotificationPet.read(file, maximum: 10 * 1024 * 1024) }
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
            #expect(throws: (any Error).self) { try MaestroNotificationPet.readBundled(file, maximum: 1024) }
            #expect(throws: (any Error).self) { try MaestroNotificationPet.read(file, maximum: 1024) }
        }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try MaestroNotificationPet.readBundled(file, maximum: 1024) == Data("synthetic".utf8))
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try MaestroNotificationPet.readBundled(link, maximum: 1024) }
        #expect(throws: (any Error).self) { try MaestroNotificationPet.read(link, maximum: 1024) }
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
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/notification-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(data: nil, width: 512, height: 624, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let sheet = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(sheet, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let bundled = folder.appendingPathComponent("maestro-pet.png")
        try (sheet as Data).write(to: bundled)
        let frame = try MaestroNotificationPet(home: folder, bundledSheet: bundled)
            .png(session: UUID(), agentChoice: "unavailable-custom-pet")
        let source = try #require(CGImageSourceCreateWithData(frame as CFData, nil))
        let cropped = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cropped.width == 64)
        #expect(cropped.height == 69)
        let file = folder.appendingPathComponent("pet.png")
        try frame.write(to: file)
        let attachment = try UNNotificationAttachment(identifier: "synthetic-pet", url: file)
        let session = UUID()
        let admission = MaestroNotificationAdmission(
            target: .init(nodeId: UUID(), sessionId: session, workspaceId: UUID(), surfaceId: UUID(), generation: 2),
            clickToken: String(repeating: "a", count: 64), name: "Synthetic"
        )
        let normal = MaestroNotificationContent(name: "Agent\u{0000}\n", state: .working,
                                               message: String(repeating: "x", count: 141), urgent: false)
            .request(admission: admission, attachment: attachment)
        let urgent = MaestroNotificationContent(name: "Agent", state: .blocked, message: "Choose one", urgent: true)
            .request(admission: admission, attachment: attachment)
        #expect(normal.content.title == "Agent")
        #expect(normal.content.body == String(repeating: "x", count: 139) + "…")
        #expect(normal.content.subtitle == "🟢 Working")
        #expect(normal.content.sound == nil)
        #expect(urgent.content.sound != nil)
        #expect(normal.content.interruptionLevel == .active && urgent.content.interruptionLevel == .active)
        #expect(urgent.content.subtitle == "Urgent · ⏸️ Needs input")
        #expect(normal.content.threadIdentifier == session.uuidString.lowercased())
        #expect(normal.identifier != urgent.identifier)
        #expect(normal.content.attachments.count == 1)
        #expect(normal.content.userInfo["maestroClickToken"] as? String == admission.clickToken)
        #expect(MaestroNotificationContent.text("a\u{202e}b\u{0007}", limit: 140) == "ab")
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
