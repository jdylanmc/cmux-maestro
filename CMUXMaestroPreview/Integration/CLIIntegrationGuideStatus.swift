import CryptoKit
import Darwin
import Foundation
import Observation

nonisolated enum CLIIntegrationGuideStatus: String, CaseIterable, Sendable {
    case unchecked, missing, unreadable, different, matching

    var title: String {
        switch self {
        case .unchecked: "Not checked"
        case .missing: "Not installed here"
        case .unreadable: "Cannot read content"
        case .different: "Different from this build"
        case .matching: "Matches this build"
        }
    }

    var symbol: String {
        switch self {
        case .unchecked: "circle.dashed"
        case .missing: "minus.circle"
        case .unreadable: "exclamationmark.circle"
        case .different: "doc.badge.ellipsis"
        case .matching: "checkmark.circle"
        }
    }
}

nonisolated enum CLIIntegrationGuideLocation: String, CaseIterable, Sendable {
    case copilot, legacy

    var relativePath: String {
        self == .copilot ? ".copilot/skills/maestro" : ".agents/skills/maestro"
    }
    var displayPath: String { "~/\(relativePath)" }
    var title: String { self == .copilot ? "Copilot copy location" : "Legacy guide location" }
}

nonisolated struct CLIIntegrationGuideInspection: Equatable, Identifiable, Sendable {
    let location: CLIIntegrationGuideLocation
    let status: CLIIntegrationGuideStatus
    let detail: String
    var id: CLIIntegrationGuideLocation { location }

    static var unchecked: [Self] {
        CLIIntegrationGuideLocation.allCases.map {
            .init(location: $0, status: .unchecked, detail: "Re-check to compare the two guide files.")
        }
    }
}

nonisolated enum CLIIntegrationGuideChecker {
    static let maximumFileBytes = 262_144
    static let baselineResource = "maestro-guide-baseline"
    private static let maximumBaselineBytes = 16_384
    private static let filenames = ["SKILL.md", "intent.md"]

    private struct Baseline: Decodable {
        let version: Int
        let files: [String: String]
    }

    static func inspect(home: URL, baseline: Data?) -> [CLIIntegrationGuideInspection] {
        guard let baseline, baseline.count <= maximumBaselineBytes,
              let expected = try? JSONDecoder().decode(Baseline.self, from: baseline),
              expected.version == 1, Set(expected.files.keys) == Set(filenames),
              expected.files.values.allSatisfy({
                  $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }) else {
            return unavailable("This build's guide baseline is missing or invalid. No installed content was compared.")
        }
        return CLIIntegrationGuideLocation.allCases.map { location in
            inspect(location, home: home, expected: expected)
        }
    }

    static func inspectInstalled() -> [CLIIntegrationGuideInspection] {
        do {
            let home = try CopilotPaths.realUserHome()
            let baseline = try bundledBaseline()
            return inspect(home: home, baseline: baseline)
        } catch {
            return unavailable("The home directory or this build's guide baseline could not be safely read. Nothing was changed.")
        }
    }

    static func bundledBaseline(bundle: Bundle = .main) throws -> Data {
        guard let resources = bundle.resourceURL else { throw CopilotFileError.missing }
        let directory = try CopilotFileAccess.openDirectory(resources)
        defer { close(directory) }
        let name = baselineResource + ".json"
        let owner = try CopilotFileAccess.statEntry(at: directory, name: name).uid
        return try readFile(at: directory, name: name, owner: owner, maximum: maximumBaselineBytes).data
    }

    private static func unavailable(_ detail: String) -> [CLIIntegrationGuideInspection] {
        CLIIntegrationGuideLocation.allCases.map {
            .init(location: $0, status: .unreadable, detail: detail)
        }
    }

    private static func inspect(
        _ location: CLIIntegrationGuideLocation, home: URL, expected: Baseline
    ) -> CLIIntegrationGuideInspection {
        func result(_ status: CLIIntegrationGuideStatus, _ detail: String) -> CLIIntegrationGuideInspection {
            .init(location: location, status: status, detail: detail)
        }
        let path = home.appendingPathComponent(location.relativePath, isDirectory: true)
        let directory: Int32
        do {
            directory = try CopilotFileAccess.openDirectory(path, owner: getuid())
        } catch CopilotFileError.missing {
            return result(.missing, "No guide directory was found at this location.")
        } catch {
            return result(.unreadable, "Cannot safely open this location. Check access and ensure it is a directory without symlinks.")
        }
        defer { close(directory) }
        do {
            let before = try CopilotFileAccess.statFile(directory)
            var missing: [String] = []
            var different: [String] = []
            var stamps: [String: CopilotFileStamp] = [:]
            for name in filenames {
                do {
                    let file = try readFile(at: directory, name: name, owner: getuid(), maximum: maximumFileBytes)
                    stamps[name] = file.stamp
                    let digest = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
                    if digest != expected.files[name] { different.append(name) }
                } catch CopilotFileError.missing {
                    missing.append(name)
                }
            }
            // Verify the pair and its location again, not only each file's read.
            let current = try CopilotFileAccess.openDirectory(path, owner: getuid())
            defer { close(current) }
            guard before == (try CopilotFileAccess.statFile(current)) else { throw CopilotFileError.changed }
            for (name, stamp) in stamps {
                guard stamp == (try CopilotFileAccess.statEntry(at: current, name: name)) else {
                    throw CopilotFileError.changed
                }
            }
            if !missing.isEmpty {
                return result(.different, "Incomplete guide: missing \(missing.joined(separator: ", ")).")
            }
            if !different.isEmpty {
                return result(.different, "\(different.joined(separator: ", ")) differs. This does not establish which copy is newer.")
            }
            return result(.matching, "SKILL.md and intent.md match the canonical guide for this build.")
        } catch CopilotFileError.tooLarge {
            return result(.unreadable, "A guide file exceeds the 256 KiB read limit. Content was not compared.")
        } catch CopilotFileError.changed {
            return result(.unreadable, "The guide changed during inspection. Re-check when the installer has finished.")
        } catch {
            return result(.unreadable, "Cannot safely read both guide files. Check access, ownership and regular file types; symlinks are not followed.")
        }
    }

    private static func readFile(
        at directory: Int32, name: String, owner: UInt32, maximum: Int
    ) throws -> (data: Data, stamp: CopilotFileStamp) {
        let file = try CopilotFileAccess.openRegular(at: directory, name: name, owner: owner)
        defer { close(file) }
        let before = try CopilotFileAccess.statFile(file)
        guard before.size >= 0, before.size <= maximum else { throw CopilotFileError.tooLarge }
        let data = try CopilotFileAccess.read(file, offset: 0, count: maximum + 1)
        guard data.count == before.size,
              before == (try CopilotFileAccess.statFile(file)),
              before == (try CopilotFileAccess.statEntry(at: directory, name: name)) else {
            throw CopilotFileError.changed
        }
        return (data, before)
    }
}

@Observable
@MainActor
final class CLIIntegrationGuideCheck {
    private(set) var inspections: [CLIIntegrationGuideInspection]
    private(set) var isChecking = false
    private(set) var checkedAt: Date?
    private let read: @Sendable () async -> [CLIIntegrationGuideInspection]

    init(
        inspections: [CLIIntegrationGuideInspection] = CLIIntegrationGuideInspection.unchecked,
        read: @escaping @Sendable () async -> [CLIIntegrationGuideInspection] = {
            await Task.detached(priority: .utility) { CLIIntegrationGuideChecker.inspectInstalled() }.value
        }
    ) {
        self.inspections = inspections
        self.read = read
    }

    func recheck() async {
        guard !isChecking else { return }
        isChecking = true
        inspections = CLIIntegrationGuideInspection.unchecked
        checkedAt = nil
        inspections = await read()
        checkedAt = Date()
        isChecking = false
    }
}
