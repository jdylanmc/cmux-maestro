import Foundation

/// Beats: saved recurring prompts for exact agent sessions. This mirrors the Python
/// orchestrator's `beats` store and cron rules (scripts/cmux-maestro-orchestrator.py); the two
/// share `scripts/test-fixtures/beats-cron-cases.json`. Policy lives in issue #42.
nonisolated enum BeatsLimits {
    static let maximumTotal = 256
    static let maximumPerSession = 16
    static let maximumPromptBytes = 4096
    static let maximumStoreBytes = 1_048_576
}

nonisolated struct BeatsError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Five numeric fields (minute hour day-of-month month weekday), evaluated in local time.
nonisolated struct BeatsCron: Equatable {
    private static let ranges: [(name: String, low: Int, high: Int)] = [
        ("minute", 0, 59), ("hour", 0, 23), ("day", 1, 31), ("month", 1, 12), ("weekday", 0, 7)
    ]
    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let dayIsStar: Bool
    let weekdayIsStar: Bool

    init(_ raw: String) throws {
        guard !raw.isEmpty, raw.count <= 100,
              !raw.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" }) else {
            throw BeatsError("Cron must be five space-separated numeric fields: minute hour day month weekday.")
        }
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else {
            throw BeatsError("Cron must have exactly five fields: minute hour day-of-month month weekday.")
        }
        var sets: [Set<Int>] = []
        var stars: [Bool] = []
        for (text, range) in zip(fields, Self.ranges) {
            var values = Set<Int>()
            for item in text.split(separator: ",", omittingEmptySubsequences: false) {
                values.formUnion(try Self.expand(String(item), range))
            }
            if range.name == "weekday" { values = Set(values.map { $0 % 7 }) }
            sets.append(values)
            stars.append(text.hasPrefix("*"))
        }
        expression = fields.joined(separator: " ")
        minutes = sets[0]; hours = sets[1]; days = sets[2]; months = sets[3]; weekdays = sets[4]
        dayIsStar = stars[2]; weekdayIsStar = stars[4]
        if !dayIsStar && weekdayIsStar {
            let possible = months.contains { month in days.contains { $0 <= Self.daysInMonth[month - 1] } }
            guard possible else { throw BeatsError("That cron expression can never match a real date.") }
        }
    }

    private static let itemPattern = /^(\*|[0-9]{1,2}(?:-[0-9]{1,2})?)(?:\/([0-9]{1,2}))?$/

    private static func expand(_ item: String, _ range: (name: String, low: Int, high: Int)) throws -> [Int] {
        guard let match = try? itemPattern.wholeMatch(in: item) else {
            throw BeatsError("Cron \(range.name) field is invalid. Use numbers, ranges, lists and steps only (for example */15 or 1-5).")
        }
        let base = String(match.output.1)
        let first: Int, last: Int
        if base == "*" {
            first = range.low; last = range.high
        } else if base.contains("-") {
            let ends = base.split(separator: "-").compactMap { Int($0) }
            first = ends[0]; last = ends[1]
        } else {
            guard match.output.2 == nil else { throw BeatsError("Cron \(range.name) step needs * or a range.") }
            first = Int(base)!; last = first
        }
        guard range.low <= first, first <= last, last <= range.high else {
            throw BeatsError("Cron \(range.name) values must be \(range.low)-\(range.high).")
        }
        var step = 1
        if let text = match.output.2 {
            step = Int(text)!
            guard step >= 1 else { throw BeatsError("Cron \(range.name) step must be at least 1.") }
        }
        return Array(stride(from: first, through: last, by: step))
    }

    /// `weekday`: cron numbering, 0 = Sunday.
    func matchesDay(month: Int, day: Int, weekday: Int) -> Bool {
        guard months.contains(month) else { return false }
        let dayOK = days.contains(day), weekdayOK = weekdays.contains(weekday)
        if dayIsStar && weekdayIsStar { return true }
        if dayIsStar { return weekdayOK }
        if weekdayIsStar { return dayOK }
        return dayOK || weekdayOK
    }

    /// Upcoming local fire times after `date`. Nonexistent local times are skipped; a repeated
    /// local minute appears once.
    func nextTimes(after date: Date, count: Int, calendar: Calendar = .current, horizonDays: Int = 800) -> [Date] {
        var results: [Date] = []
        guard let startOfDay = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) else { return [] }
        for offset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
                  matchesDay(month: month, day: dayOfMonth, weekday: weekday - 1) else { continue }
            for hour in hours.sorted() {
                for minute in minutes.sorted() {
                    var wanted = DateComponents()
                    wanted.year = parts.year; wanted.month = month; wanted.day = dayOfMonth
                    wanted.hour = hour; wanted.minute = minute
                    guard let candidate = calendar.date(from: wanted), candidate > date else { continue }
                    let actual = calendar.dateComponents([.day, .hour, .minute], from: candidate)
                    guard actual.day == dayOfMonth, actual.hour == hour, actual.minute == minute else { continue }
                    results.append(candidate)
                    if results.count == count { return results }
                }
            }
        }
        return results
    }
}

nonisolated struct SidebarBeat: Codable, Equatable, Identifiable {
    static let fieldNames: Set<String> = [
        "id", "sessionId", "cron", "prompt", "enabled", "recoveryGate", "targetEnded",
        "lastFiredMinute", "createdAt", "updatedAt", "revision"
    ]
    var id: String
    var sessionId: String
    var cron: String
    var prompt: String
    var enabled: Bool
    var recoveryGate: Bool
    var targetEnded: Bool
    var lastFiredMinute: String?
    var createdAt: String
    var updatedAt: String
    var revision: Int

    /// The orchestrator writes `lastFiredMinute: null`; keep the key present for parity.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(cron, forKey: .cron)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(recoveryGate, forKey: .recoveryGate)
        try container.encode(targetEnded, forKey: .targetEnded)
        if let lastFiredMinute { try container.encode(lastFiredMinute, forKey: .lastFiredMinute) }
        else { try container.encodeNil(forKey: .lastFiredMinute) }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(revision, forKey: .revision)
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, cron, prompt, enabled, recoveryGate, targetEnded
        case lastFiredMinute, createdAt, updatedAt, revision
    }

    /// Why recurrence is not running, if it is not.
    var status: SidebarBeatStatus {
        if targetEnded { return .targetEnded }
        if recoveryGate { return .needsRecovery }
        return enabled ? .active : .paused
    }
}

nonisolated enum SidebarBeatStatus: Equatable {
    case active, paused, needsRecovery, targetEnded
    var title: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .needsRecovery: "Needs recovery"
        case .targetEnded: "Target ended"
        }
    }
}

nonisolated struct SidebarBeatsState: Equatable {
    var beats: [SidebarBeat] = []

    static func validatePrompt(_ prompt: String) throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BeatsError("A Beat needs a nonempty prompt.")
        }
        guard prompt.utf8.count <= BeatsLimits.maximumPromptBytes,
              !prompt.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else {
            throw BeatsError("A Beat prompt must be at most 4 KiB of text without control characters.")
        }
        return prompt
    }

    static func canonicalUUID(_ value: String) -> String? {
        guard value.count == 36, let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return nil }
        return value
    }

    static func decode(_ data: Data) throws -> SidebarBeatsState {
        guard data.count <= BeatsLimits.maximumStoreBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "beats"], object["version"] as? Int == 1,
              let raw = object["beats"] as? [[String: Any]], raw.count <= BeatsLimits.maximumTotal,
              raw.allSatisfy({ Set($0.keys) == SidebarBeat.fieldNames }),
              let beats = try? JSONDecoder().decode([SidebarBeat].self, from: JSONSerialization.data(withJSONObject: raw))
        else { throw BeatsError("The Beats store is invalid or from a newer version.") }
        var seen = Set<String>()
        for beat in beats {
            _ = try BeatsCron(beat.cron)
            _ = try validatePrompt(beat.prompt)
            guard Self.canonicalUUID(beat.id) != nil, Self.canonicalUUID(beat.sessionId) != nil,
                  seen.insert(beat.id).inserted, beat.revision >= 1 else {
                throw BeatsError("The Beats store has an inconsistent definition.")
            }
        }
        return SidebarBeatsState(beats: beats)
    }

    func encoded() throws -> Data {
        // Match the orchestrator's sorted, compact encoding.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Envelope: Encodable { let version = 1; let beats: [SidebarBeat] }
        let data = try encoder.encode(Envelope(beats: beats)) + Data([10])
        guard data.count <= BeatsLimits.maximumStoreBytes else { throw BeatsError("The Beats store size limit was reached.") }
        return data
    }

    // MARK: Human operations (the sidebar is the human actor)

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    mutating func create(session: UUID, cron: String, prompt: String) throws -> SidebarBeat {
        let spec = try BeatsCron(cron)
        let text = try Self.validatePrompt(prompt)
        let sessionID = session.uuidString.lowercased()
        guard beats.count < BeatsLimits.maximumTotal,
              beats.filter({ $0.sessionId == sessionID }).count < BeatsLimits.maximumPerSession else {
            throw BeatsError("The Beat limit was reached; delete one first.")
        }
        let stamp = Self.stamp()
        let beat = SidebarBeat(
            id: UUID().uuidString.lowercased(), sessionId: sessionID, cron: spec.expression, prompt: text,
            enabled: true, recoveryGate: false, targetEnded: false, lastFiredMinute: nil,
            createdAt: stamp, updatedAt: stamp, revision: 1)
        beats.append(beat)
        return beat
    }

    private func index(_ id: String) throws -> Int {
        guard let position = beats.firstIndex(where: { $0.id == id }) else {
            throw BeatsError("That Beat no longer exists.")
        }
        return position
    }

    /// Cron, prompt and (repair) target may change; enabled and recovery state do not.
    mutating func edit(id: String, cron: String?, prompt: String?, session: UUID?) throws {
        let position = try index(id)
        var beat = beats[position]
        if let cron { beat.cron = try BeatsCron(cron).expression }
        if let prompt { beat.prompt = try Self.validatePrompt(prompt) }
        if let session {
            let target = session.uuidString.lowercased()
            if target != beat.sessionId {
                guard beats.filter({ $0.sessionId == target }).count < BeatsLimits.maximumPerSession else {
                    throw BeatsError("That session already has the maximum number of Beats.")
                }
                beat.sessionId = target
                // Repair never silently resumes: a human re-enables after choosing the target.
                beat.enabled = false
                beat.recoveryGate = true
                beat.targetEnded = false
                beat.lastFiredMinute = nil
            }
        }
        beat.updatedAt = Self.stamp(); beat.revision += 1
        beats[position] = beat
    }

    mutating func pause(id: String) throws {
        let position = try index(id)
        beats[position].enabled = false
        beats[position].updatedAt = Self.stamp(); beats[position].revision += 1
    }

    /// Only a human clears the recovery gate (first recurring enable after relaunch or repair).
    mutating func enable(id: String) throws {
        let position = try index(id)
        guard !beats[position].targetEnded else {
            throw BeatsError("Choose an existing session for this Beat before re-enabling it.")
        }
        beats[position].enabled = true
        beats[position].recoveryGate = false
        beats[position].updatedAt = Self.stamp(); beats[position].revision += 1
    }

    mutating func delete(id: String) throws {
        beats.remove(at: try index(id))
    }
}

/// One authoritative store shared with the orchestrator: writers serialize on a lock file and
/// replace the data file atomically.
nonisolated struct SidebarBeatsFile {
    let root: URL

    init(root: URL) { self.root = root }

    static func standard() -> SidebarBeatsFile? {
        (try? CopilotPaths.realUserHome()).map {
            SidebarBeatsFile(root: $0.appendingPathComponent("Library/Application Support/CMUXMaestroPreview/Beats", isDirectory: true))
        }
    }

    func mutate<Result>(_ operation: (inout SidebarBeatsState) throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw BeatsError("The Beats store could not be opened.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw BeatsError("The Beats store is busy.") }
        defer { flock(lock, LOCK_UN) }
        var state = try readLocked()
        let result = try operation(&state)
        try write(state)
        return result
    }

    func read() throws -> SidebarBeatsState {
        guard FileManager.default.fileExists(atPath: root.path) else { return SidebarBeatsState() }
        let lock = open(root.appendingPathComponent(".lock").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if lock >= 0 {
            defer { close(lock) }
            _ = flock(lock, LOCK_SH)
            defer { flock(lock, LOCK_UN) }
            return try readLocked()
        }
        return try readLocked()
    }

    private func readLocked() throws -> SidebarBeatsState {
        let path = root.appendingPathComponent("beats.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return SidebarBeatsState() }
            throw BeatsError("The Beats store could not be read.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= BeatsLimits.maximumStoreBytes else {
            throw BeatsError("The Beats store is not a private regular file within its size limit.")
        }
        let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readData(ofLength: BeatsLimits.maximumStoreBytes + 1)
        return try SidebarBeatsState.decode(data)
    }

    private func write(_ state: SidebarBeatsState) throws {
        let data = try state.encoded()
        let temporary = root.appendingPathComponent(".pending-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BeatsError("The Beats store could not be written.") }
        var failed = false
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { failed = true; break }
                offset += written
            }
        }
        if !failed { failed = fsync(descriptor) != 0 }
        close(descriptor)
        if failed || rename(temporary.path, root.appendingPathComponent("beats.json").path) != 0 {
            unlink(temporary.path)
            throw BeatsError("The Beats store could not be written.")
        }
    }
}
