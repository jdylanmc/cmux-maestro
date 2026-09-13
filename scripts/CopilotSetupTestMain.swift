import Testing
import Darwin

@main
struct CopilotSetupTestMain {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
