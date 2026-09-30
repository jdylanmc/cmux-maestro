import Testing
import Darwin
import Foundation

@main
struct CopilotSetupTestMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--maestro-process-proof-fixture" {
            exit(await MaestroProcessProofFixture.run())
        }
        if CommandLine.arguments.dropFirst().first == "--coordinate-copilot-install" {
            exit(await CopilotInstallBridgeProcessFixture.run(Array(CommandLine.arguments.dropFirst())))
        }
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
