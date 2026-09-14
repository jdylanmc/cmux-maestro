import Foundation

@main
struct PreferenceCoordinationTestClient {
    static let sessionID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    static let eventID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!

    @MainActor
    static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let defaults = UserDefaults(suiteName: CommandLine.arguments[2])!
        let attentionFile = URL(fileURLWithPath: CommandLine.arguments[3])
        let layoutFile = URL(fileURLWithPath: CommandLine.arguments[4])
        let preferences = SidebarPreferences(
            defaults: defaults, historyFile: file, attentionFile: attentionFile,
            layoutStore: .init(file: .init(url: layoutFile))
        )
        let attention = PreferenceAttentionFixture()
        emit("ready")
        while let line = await Task.detached(operation: { readLine() }).value {
            let args = line.split(separator: " ").map(String.init)
            switch args.first {
            case "dismiss":
                emit("applying")
                preferences.dismiss([key(args[1])])
            case "retain":
                preferences.setRetention(SidebarHistoryRetention(rawValue: args[1])!)
            case "restore":
                preferences.restoreDismissed()
            case "reset":
                preferences.resetHistory()
            case "density":
                preferences.setDensity(SidebarDensity(rawValue: args[1])!)
            case "collapse":
                emit("applying")
                preferences.setExpanded(false, for: .workspace(UUID(uuidString: args[1])!))
            case "expand-all":
                preferences.expandAll()
            case "reset-layout":
                preferences.resetLayout()
            case "hold-layout":
                let result = SidebarLayoutFile(url: layoutFile).coordinatedFile.update { value in
                    emit("locked")
                    guard readLine() == "continue" else { throw CocoaError(.userCancelled) }
                    value.setExpanded(false, for: .workspace(UUID(uuidString: args[1])!))
                }
                guard result.notice == nil else { throw CocoaError(.fileWriteUnknown) }
            case "expect-layout":
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while preferences.layout.collapsed.count != Int(args[1])!
                    || preferences.layout.density.rawValue != args[2] || preferences.layoutNotice != nil {
                    guard ContinuousClock.now < deadline else { throw CocoaError(.coderValueNotFound) }
                    try await Task.sleep(for: .milliseconds(10))
                }
            case "ack":
                emit("applying")
                preferences.acknowledge(
                    [attention.key(args[1])],
                    in: attention.tree(history: preferences.history, attention: preferences.attention)
                )
            case "reset-ack":
                preferences.resetAcknowledgements()
            case "hold-ack":
                let result = SidebarPreferenceFile<SidebarAttentionSettings>(url: attentionFile).update { value in
                    emit("locked")
                    guard readLine() == "continue" else { throw CocoaError(.userCancelled) }
                    value.acknowledged.insert(attention.key(args[1]))
                }
                guard result.notice == nil else { throw CocoaError(.fileWriteUnknown) }
            case "expect-ack":
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while preferences.attention.acknowledged.count != Int(args[1])! || preferences.attentionNotice != nil {
                    guard ContinuousClock.now < deadline else { throw CocoaError(.coderValueNotFound) }
                    try await Task.sleep(for: .milliseconds(10))
                }
            case "hold":
                // Deterministically pause a real cross-process transaction after its read.
                let result = SidebarPreferenceFile<SidebarHistorySettings>(url: file).update { value in
                    emit("locked")
                    guard readLine() == "continue" else { throw CocoaError(.userCancelled) }
                    value.dismissed.insert(key(args[1]))
                }
                guard result.notice == nil else { throw CocoaError(.fileWriteUnknown) }
            case "expect":
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while preferences.history.dismissed.count != Int(args[1])!
                    || preferences.history.retention.rawValue != args[2] {
                    guard ContinuousClock.now < deadline else { throw CocoaError(.coderValueNotFound) }
                    try await Task.sleep(for: .milliseconds(10))
                }
            case "quit":
                return
            default:
                throw CocoaError(.coderInvalidValue)
            }
            guard preferences.historyNotice == nil, preferences.attentionNotice == nil,
                  preferences.layoutNotice == nil else { throw CocoaError(.fileWriteUnknown) }
            emit("done")
        }
    }

    static func key(_ child: String) -> SidebarDismissedOutcome {
        .init(sessionID: sessionID, childID: child, eventID: eventID)
    }

    static func emit(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }
}
