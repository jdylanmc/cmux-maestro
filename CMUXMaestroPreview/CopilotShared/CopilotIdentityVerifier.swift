import Darwin
import Foundation

nonisolated struct CopilotProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init(pid: Int32, parentPID: Int32, uid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

nonisolated enum CopilotProcessLookup: Equatable, Sendable {
    case found(CopilotProcessIdentity)
    case dead
    case unavailable
}

nonisolated enum CopilotProcessProbe {
    static func read(_ pid: Int32) -> CopilotProcessLookup {
        guard pid > 0 else { return .dead }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let count = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard count == size else {
            return errno == ESRCH ? .dead : .unavailable
        }
        if info.pbi_status == UInt32(SZOMB) { return .dead }
        guard info.pbi_uid == getuid() else { return .unavailable }
        return .found(CopilotProcessIdentity(
            pid: pid, parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec
        ))
    }
}

nonisolated enum CopilotIdentityStatus: Equatable, Sendable {
    case alive, dead, unknown, ambiguous, changed, unsupported
}

nonisolated struct CopilotIdentityEvidence: Equatable, Sendable {
    let status: CopilotIdentityStatus
    let process: CopilotProcessIdentity?
    let markers: [String: CopilotFileStamp]

    init(
        status: CopilotIdentityStatus, process: CopilotProcessIdentity? = nil,
        markers: [String: CopilotFileStamp] = [:]
    ) {
        self.status = status
        self.process = process
        self.markers = markers
    }
}

nonisolated struct CopilotIdentityVerifier: Sendable {
    let uid: UInt32
    let lookup: @Sendable (Int32) -> CopilotProcessLookup

    init(
        uid: UInt32 = getuid(),
        lookup: @escaping @Sendable (Int32) -> CopilotProcessLookup = CopilotProcessProbe.read
    ) {
        self.uid = uid
        self.lookup = lookup
    }

    func inspect(record: CopilotIdentityRecord, sessionDirectory: Int32) throws -> CopilotIdentityEvidence {
        guard record.schemaVersion == 1 else { return .init(status: .unsupported) }
        let owner: CopilotProcessIdentity?
        let absentStatus: CopilotIdentityStatus
        switch lookup(record.ownerPID) {
        case .dead:
            owner = nil
            absentStatus = .dead
        case .unavailable:
            owner = nil
            absentStatus = .unknown
        case .found(let value):
            guard value.uid == uid, value.pid == record.ownerPID,
                  value.startSeconds == record.ownerStartSeconds,
                  value.startMicroseconds == record.ownerStartMicroseconds else {
                return .init(status: .changed)
            }
            owner = value
            absentStatus = .unknown
        }

        let entries = try CopilotFileAccess.names(at: sessionDirectory, limit: 512)
        guard !entries.limited else { return .init(status: .ambiguous) }
        var live: [String: CopilotFileStamp] = [:]
        var uncertain = false
        for name in entries.names where name.hasPrefix("inuse.") && name.hasSuffix(".lock") {
            try Task.checkCancellation()
            let digits = name.dropFirst(6).dropLast(5)
            guard let pid = Int32(digits), pid > 0, String(pid) == digits else {
                uncertain = true
                continue
            }
            let stamp = try CopilotFileAccess.statEntry(at: sessionDirectory, name: name)
            guard stamp.isRegular, stamp.uid == uid else {
                uncertain = true
                continue
            }
            switch lookup(pid) {
            case .dead: continue
            case .unavailable: uncertain = true
            case .found(let process):
                guard process.uid == uid, process.pid == pid,
                      Self.marker(stamp, wasBornAfter: process) else {
                    uncertain = true
                    continue
                }
                live[name] = stamp
            }
        }
        guard !uncertain, live.count <= 1 else { return .init(status: .ambiguous) }
        guard let owner else {
            return .init(status: live.isEmpty ? absentStatus : .ambiguous)
        }
        let expected = "inuse.\(record.ownerPID).lock"
        guard live[expected] != nil else {
            return .init(status: live.isEmpty ? .unknown : .ambiguous)
        }
        return .init(status: .alive, process: owner, markers: live)
    }

    func verifyStable(
        _ before: CopilotIdentityEvidence, record: CopilotIdentityRecord, sessionDirectory: Int32
    ) throws -> CopilotIdentityEvidence {
        let after = try inspect(record: record, sessionDirectory: sessionDirectory)
        guard before == after else {
            return .init(status: after.status == .ambiguous ? .ambiguous : .changed)
        }
        return after
    }

    private static func marker(_ marker: CopilotFileStamp, wasBornAfter process: CopilotProcessIdentity) -> Bool {
        guard marker.birthSeconds >= 0 else { return false }
        return UInt64(marker.birthSeconds) > process.startSeconds
            || (UInt64(marker.birthSeconds) == process.startSeconds
                && UInt64(max(0, marker.birthNanoseconds)) >= process.startMicroseconds * 1_000)
    }
}
