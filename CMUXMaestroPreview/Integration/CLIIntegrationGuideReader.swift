import CryptoKit
import Darwin
import Foundation

actor CLIIntegrationGuideReader {
    nonisolated enum Content: Equatable, Sendable {
        case missing
        case unreadable(CopilotFileError)
        case different
        case matching

        var title: String {
            switch self {
            case .missing: String(localized: "Missing")
            case .unreadable: String(localized: "Unreadable")
            case .different: String(localized: "Different from this build")
            case .matching: String(localized: "Matches this build")
            }
        }

        var detail: String {
            switch self {
            case .missing: String(localized: "No guide found at this location.")
            case .different: String(localized: "Content may be newer or customized; different does not mean outdated.")
            case .matching: String(localized: "Guide bytes match this build, not necessarily the latest upstream guide.")
            case .unreadable(let error):
                switch error {
                case .permissionDenied: String(localized: "Permission denied. Check access, then Re-check.")
                case .tooLarge: String(localized: "Guide exceeds the 64 KiB read limit.")
                case .changed: String(localized: "Guide changed during the read. Re-check to try again.")
                case .unsafePath: String(localized: "Unsupported file type or broken symbolic link.")
                case .missing, .io: String(localized: "Guide could not be read. Check the file, then Re-check.")
                }
            }
        }
    }

    nonisolated struct Observation: Equatable, Sendable, Identifiable {
        let relativePath: String
        let content: Content
        var id: String { relativePath }
        var displayPath: String { "~/" + relativePath }
    }

    nonisolated enum Result: Equatable, Sendable {
        case referenceUnavailable
        case checked([Observation])
    }

    // These are observed/documented global discovery locations, not a loaded-skill registry.
    nonisolated static let relativePaths = [
        ".agents/skills/maestro/SKILL.md",
        ".copilot/skills/maestro/SKILL.md"
    ]
    nonisolated static let maximumBytes = 65_536
    private let home: URL
    private let reference: URL?

    init(home: URL, reference: URL?) {
        self.home = home
        self.reference = reference
    }

    func check() -> Result {
        let expected: String
        do {
            guard let reference else { return .referenceUnavailable }
            let data = try Self.readStable(reference, maximum: 65)
            guard data.count == 65, data.last == 10,
                  data.dropLast().allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return .referenceUnavailable
            }
            expected = String(decoding: data.dropLast(), as: UTF8.self)
        } catch {
            return .referenceUnavailable
        }
        return .checked(Self.relativePaths.map { path in
            let content: Content
            do {
                let data = try Self.readStable(home.appendingPathComponent(path), maximum: Self.maximumBytes)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                content = digest == expected ? .matching : .different
            } catch CopilotFileError.missing {
                content = .missing
            } catch let error as CopilotFileError {
                content = .unreadable(error)
            } catch {
                content = .unreadable(.io)
            }
            return Observation(relativePath: path, content: content)
        })
    }

    /// Follows installer-created links, but reads only a bounded, stable regular file.
    /// The shared private-file reader deliberately rejects links; do not relax it.
    nonisolated static func readStable(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = try openFile(url)
        defer { close(descriptor) }
        let before = try CopilotFileAccess.statFile(descriptor)
        guard before.isRegular else { throw CopilotFileError.unsafePath }
        guard before.size >= 0, before.size <= maximum else { throw CopilotFileError.tooLarge }
        let bytes = try CopilotFileAccess.read(descriptor, offset: 0, count: maximum + 1)
        let current = try openFile(url)
        defer { close(current) }
        guard bytes.count == before.size, bytes.count <= maximum,
              before == (try CopilotFileAccess.statFile(descriptor)),
              before == (try CopilotFileAccess.statFile(current)) else {
            throw CopilotFileError.changed
        }
        return bytes
    }

    private nonisolated static func openFile(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw CopilotFileError.unsafePath }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 128 else { throw CopilotFileError.unsafePath }
        var directory = Darwin.open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CopilotFileError.current() }
        defer { close(directory) }
        for (index, part) in parts.enumerated() {
            guard part != ".", part != "..", !part.utf8.contains(0) else {
                throw CopilotFileError.unsafePath
            }
            let final = index == parts.count - 1
            let flags = final ? O_RDONLY | O_NONBLOCK : O_SEARCH | O_DIRECTORY
            let next = openat(directory, part, flags | O_CLOEXEC)
            guard next >= 0 else {
                let error = CopilotFileError.current()
                if error == .missing {
                    var entry = stat()
                    if fstatat(directory, part, &entry, AT_SYMLINK_NOFOLLOW) == 0 {
                        throw CopilotFileError.unsafePath
                    }
                }
                throw error
            }
            if final { return next }
            close(directory)
            directory = next
        }
        throw CopilotFileError.unsafePath
    }
}
