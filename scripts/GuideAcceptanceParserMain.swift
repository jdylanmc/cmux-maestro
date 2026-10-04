import Foundation

/// Non-GUI executable used only by parser contract tests, never a native producer.
@main
struct GuideAcceptanceParserMain {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            if arguments.dropFirst().first == "--finalization-control" {
                try finalizationControl(arguments)
                return
            }
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

    private static func finalizationControl(_ arguments: [String]) throws {
        guard arguments.count == 4, let before = Double(arguments[2]), let after = Double(arguments[3]) else {
            throw GuideAcceptanceEvidence.Failure(description: "Expected before/after teardown elapsed seconds")
        }
        var elapsed = before
        var terminations = 0
        var finalization = GuideAcceptanceEvidence.Finalization()
        var failure: Error?
        do {
            try finalization.finish(remaining: {
                let remaining = 180 - elapsed
                try GuideAcceptanceEvidence.require(remaining > 0, "180-second entire native acceptance case exceeded")
                return remaining
            }, terminate: {
                terminations += 1
                elapsed = after
            })
        } catch {
            failure = error
        }
        // Exercise the same deferred failure/success cleanup, without any application.
        finalization.terminate { terminations += 1 }
        let result: [String: Any] = [
            "terminationCalls": terminations, "elapsed": elapsed, "terminated": finalization.terminated
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        if let failure { throw failure }
    }
}
