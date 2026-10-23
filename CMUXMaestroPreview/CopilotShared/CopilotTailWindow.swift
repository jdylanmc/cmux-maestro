/// A human-selected bound on unseen event history, not a request to backfill it.
nonisolated struct CopilotTailWindow: Equatable, Sendable {
    static let defaultMiB = 4
    static let range = 1...64

    let mebibytes: Int
    var bytes: Int { mebibytes * 1_048_576 }

    init?(mebibytes: Int) {
        guard Self.range.contains(mebibytes) else { return nil }
        self.mebibytes = mebibytes
    }
}
