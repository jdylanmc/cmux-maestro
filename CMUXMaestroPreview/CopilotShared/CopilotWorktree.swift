import Foundation

// Value types shared by the observer hook, the reader and the sidebar. No file access here.

/// Verified worktree, confirmed non-repository directory, or unknown. Unknown is never non-repository.
nonisolated enum CopilotWorktreeEvidence: Codable, Hashable, Sendable {
    case verified(CopilotWorktreeIdentity)
    case nonRepository
    case unknown
}

nonisolated struct CopilotWorktreeIdentity: Codable, Hashable, Sendable {
    static let maximumLabelBytes = 200
    /// Opaque grouping key: a digest of the worktree's own Git directory. Two worktrees of one
    /// repository differ; the same worktree keeps it across branch changes.
    let key: String
    /// Display only: the repository's directory name. Never identity.
    let repository: String
    let head: CopilotWorktreeHead
    /// A linked worktree (`git worktree add`), not the repository's main worktree.
    let linked: Bool

    /// Short display form of the key.
    var shortKey: String { String(key.prefix(7)) }

    static func validKey(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLabelBytes && !value.contains("/")
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }
    }
}

nonisolated enum CopilotWorktreeHead: Codable, Hashable, Sendable {
    case branch(String)
    /// Detached HEAD: the abbreviated commit.
    case detached(String)

    static func validCommit(_ value: String) -> Bool {
        value.utf8.count == 7 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The worktree a session's own selected directory is in (ADR 0027). `isCurrent` is false when
/// the evidence is last known: the session's directory record changed since, or was not read live.
nonisolated struct AgentSessionWorktree: Codable, Equatable, Sendable {
    let evidence: CopilotWorktreeEvidence
    let isCurrent: Bool
}

// Display sanitiser shared with sidebar metadata. Removes C0/C1 controls (Cc) and
// bidirectional controls; keeps other format characters such as ZWJ and ZWNJ.
nonisolated enum CopilotDisplayText {
    static let bidirectionalControls = CharacterSet(charactersIn:
        "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    static func sanitize(_ value: String, limit: Int) -> String? {
        let kept = value.unicodeScalars.filter {
            $0.properties.generalCategory != .control && !bidirectionalControls.contains($0)
        }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(limit))
    }
}
