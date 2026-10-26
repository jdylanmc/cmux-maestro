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
            try MaestroNotificationCommunication.requireEntitlement()
            let admission = try await controller.authorize()
            let reader = CopilotSessionReader()
            let appearance = try await reader.sessionAppearance(for: admission.target.sessionId)
            let home = try CopilotPaths.realUserHome()
            let choice = try await Task.detached {
                try MaestroNotificationAppearance(home: home).choice(session: admission.target.sessionId, agent: appearance)
            }.value
            let png = try MaestroNotificationAvatar(catalog: SidebarGlyphCatalog.shared.get()).png(choice: choice)
            let content = MaestroNotificationContent(message: message, urgent: request.priority == "urgent")
            let notification = content.request(admission: admission)
            let communication = MaestroNotificationCommunication()
            let interaction = communication.interaction(admission: admission, message: message, avatar: png, id: notification.identifier)
            let center = SystemMaestroNotificationCenter(center: .current())
            try await MaestroNotificationDelivery(center: center).submit(notification, prepare: {
                try await communication.prepare($0, interaction: interaction)
            }) {
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
