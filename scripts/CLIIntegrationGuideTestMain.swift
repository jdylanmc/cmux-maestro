import Darwin
import Testing

@main
struct CLIIntegrationGuideTestMain {
    static func main() async {
        exit(await Testing.__swiftPMEntryPoint())
    }
}
