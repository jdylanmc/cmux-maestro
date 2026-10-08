import Foundation
import Observation

@MainActor @Observable
final class CLIIntegrationGuideModel {
    private(set) var isChecking = false
    private(set) var result: CLIIntegrationGuideReader.Result?
    private(set) var copyNotice: String?
    private let read: @Sendable () async -> CLIIntegrationGuideReader.Result

    init(read: @escaping @Sendable () async -> CLIIntegrationGuideReader.Result) {
        self.read = read
    }

    convenience init() {
        let reader = CLIIntegrationGuideReader(
            home: FileManager.default.homeDirectoryForCurrentUser,
            reference: Bundle.main.url(forResource: "maestro-guide", withExtension: "sha256")
        )
        self.init(read: { await reader.check() })
    }

    func recheck() async {
        guard !isChecking else { return }
        isChecking = true
        result = nil
        let next = await read()
        result = next
        isChecking = false
    }

    func copyCommand(using copy: () -> Bool) {
        copyNotice = copy()
            ? String(localized: "Copied. Run the command in your terminal when ready.")
            : String(localized: "Could not copy the command. Select and copy the text above.")
    }
}
