import Darwin
import Foundation
import UserNotifications

@MainActor
struct MaestroNotificationCommand {
    static let flag = "--maestro-notify"

    static func perform() async -> Int32 {
        do {
            guard CopilotSetupAccess.currentAppAllowsChanges, CommandLine.arguments.count == 2 else {
                throw MaestroNotificationFailure.unavailable
            }
            let input = try await Task.detached { try readInput() }.value
            struct Input: Decodable { let message: String; let priority: String }
            guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
                  Set(object.keys) == ["message", "priority"] else { throw MaestroNotificationFailure.invalidInput }
            let request = try JSONDecoder().decode(Input.self, from: input)
            let message = MaestroNotificationContent.text(request.message, limit: 140)
            guard !message.isEmpty, ["normal", "urgent"].contains(request.priority) else {
                throw MaestroNotificationFailure.invalidInput
            }
            let controller = try MaestroNotificationController.installed()
            let admission = try await controller.authorize()
            let reader = CopilotSessionReader()
            let snapshot = try await reader.read(surfaceIDs: [admission.target.surfaceId])
            let observation = snapshot.sessions.first {
                $0.sessionID == admission.target.sessionId && $0.surfaceID == admission.target.surfaceId
                    && $0.launchWorkspaceID == admission.target.workspaceId
            }
            let name = observation?.sessionName ?? admission.name
            let state = snapshot.isComplete ? observation?.state ?? .unknown : .unknown
            let home = try CopilotPaths.realUserHome()
            guard let sheet = Bundle.main.url(forResource: "maestro-pet", withExtension: "webp") else {
                throw MaestroNotificationFailure.unavailable
            }
            let png = try await Task.detached {
                try MaestroNotificationPet(home: home, bundledSheet: sheet)
                    .png(session: admission.target.sessionId, agentChoice: observation?.petId)
            }.value
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("maestro-notify-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = temporary.appendingPathComponent("pet.png")
            try png.write(to: file)
            let attachment = try UNNotificationAttachment(identifier: "pet", url: file)
            let content = MaestroNotificationContent(name: name, state: state, message: message, urgent: request.priority == "urgent")
            let center = SystemMaestroNotificationCenter(center: .current())
            try await MaestroNotificationDelivery(center: center).submit(content.request(admission: admission, attachment: attachment)) {
                try await controller.confirm(token: admission.clickToken)
            }
            FileHandle.standardOutput.write(Data("{\"ok\":true,\"submitted\":true,\"delivery\":\"unconfirmed\"}\n".utf8))
            return 0
        } catch {
            let reason = (error as? MaestroNotificationFailure)?.rawValue ?? MaestroNotificationFailure.unavailable.rawValue
            FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"\(reason)\"}\n".utf8))
            return 2
        }
    }

    nonisolated private static func readInput() throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var data = Data()
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) >= 0 else { throw MaestroNotificationFailure.invalidInput }
            if descriptor.revents == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return data }
            guard count > 0, data.count + count <= 16_384 else { throw MaestroNotificationFailure.invalidInput }
            data.append(contentsOf: bytes.prefix(count))
        }
        throw MaestroNotificationFailure.invalidInput
    }
}
