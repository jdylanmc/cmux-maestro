import AppKit

enum CLIIntegrationGuide {
    static let installCommand = "npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy"

    static func copyInstallCommand(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return copyInstallCommand { pasteboard.setString($0, forType: .string) }
    }

    static func copyInstallCommand(write: (String) -> Bool) -> Bool {
        write(installCommand)
    }
}
