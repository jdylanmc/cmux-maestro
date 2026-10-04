import Foundation

/// Non-GUI executable used only by parser contract tests, never a native producer.
@main
struct GuideAcceptanceParserMain {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            try GuideAcceptanceEvidence.require(arguments.count == 7, "Expected case/file/invocation/head/tree/images")
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let evidence = try JSONDecoder().decode(GuideAcceptanceEvidence.self, from: data)
            try evidence.validate(caseName: arguments[1], expectedInvocation: arguments[3],
                                  head: arguments[4], tree: arguments[5],
                                  imageDirectory: URL(fileURLWithPath: arguments[6]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
