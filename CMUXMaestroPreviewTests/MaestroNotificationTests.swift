import Foundation
import Testing
import UserNotifications
import CoreGraphics
import ImageIO
@testable import CMUXMaestroPreview

@MainActor
struct MaestroNotificationTests {
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(data: nil, width: 512, height: 624, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let sheet = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(sheet, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let frame = try MaestroNotificationPet.idleFrame(sheet as Data)
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
