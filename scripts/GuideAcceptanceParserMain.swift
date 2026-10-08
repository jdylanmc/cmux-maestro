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
            if arguments.dropFirst().first == "--observation-control" {
                try observationControl(arguments)
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

    private static func observationControl(_ arguments: [String]) throws {
        try GuideAcceptanceEvidence.require(arguments.count == 3, "Expected observation control mode")
        let mode = arguments[2]
        try GuideAcceptanceEvidence.require(
            ["ready", "pending", "false", "expired", "late-ready", "late-pending", "cancelled"].contains(mode),
            "Unknown observation control mode")
        var elapsed = mode == "expired" ? 180.0 : 179.0
        var evaluations = 0
        var waits = 0
        var timeout: Double?
        var failure: Error?
        let predicate = NSPredicate { _, _ in
            evaluations += 1
            if mode == "late-ready" { elapsed = 180 }
            return mode == "ready" || mode == "late-ready"
        }
        do {
            try GuideAcceptanceEvidence.waitForObservation(remaining: {
                let remaining = 180 - elapsed
                try GuideAcceptanceEvidence.require(remaining > 0, "180-second entire native acceptance case exceeded")
                return remaining
            }, evaluate: {
                predicate.evaluate(with: nil)
            }, pending: { remaining in
                waits += 1
                timeout = remaining
                if mode == "cancelled" { throw CancellationError() }
                elapsed = mode == "late-pending" ? 180 : 179.5
                return mode != "false"
            })
        } catch {
            failure = error
        }
        var result: [String: Any] = ["evaluations": evaluations, "waits": waits, "elapsed": elapsed]
        if let timeout { result["timeout"] = timeout }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        if let failure { throw failure }
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
