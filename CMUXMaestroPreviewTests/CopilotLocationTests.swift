import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

private typealias Resolver = CMUXMaestroPreview.CopilotLocationResolver
private typealias Location = CMUXMaestroPreview.CopilotSessionLocation

private struct LocationScratch {
    let root: URL

    init(underBuild: Bool = false) throws {
        // Hook state needs a user-owned ancestor chain; repositories need an ancestor-free tree.
        let base = underBuild
            ? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/location-fixtures", isDirectory: true)
            : FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("maestro-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func repo(_ name: String, head: String = "ref: refs/heads/main\n") throws -> URL {
        try write(head, "\(name)/.git/HEAD")
        try write("", "\(name)/src/file.swift")
        return root.appendingPathComponent(name)
    }

    func worktree(_ name: String, branch: String, gitdirParent: String = "worktrees") throws -> URL {
        try write("ref: refs/heads/\(branch)\n", "main/.git/\(gitdirParent)/\(name)/HEAD")
        try write("gitdir: \(root.path)/main/.git/\(gitdirParent)/\(name)\n", "\(name)/.git")
        return root.appendingPathComponent(name)
    }
}

struct CopilotLocationTests: Sendable {
    private let home = "/Users/example"

    private func resolve(_ payload: [String: Any]) -> Location? { Resolver.resolve(payload: payload, home: home) }

    @Test func plainRepositoryReportsBranchAndNestedDirectoriesWalkUp() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let repo = try scratch.repo("plain", head: "ref: refs/heads/feat/a-b\n")
        #expect(resolve(["cwd": repo.path]) == Location(branch: "feat/a-b", worktree: false))
        #expect(resolve(["cwd": repo.appendingPathComponent("src").path]) == Location(branch: "feat/a-b", worktree: false))
        #expect(resolve(["cwd": repo.appendingPathComponent("src/missing/deeper").path])?.branch == "feat/a-b")
    }

    @Test func linkedWorktreeReportsItsOwnBranch() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        _ = try scratch.repo("main", head: "ref: refs/heads/main\n")
        let tree = try scratch.worktree("linked", branch: "topic")
        #expect(resolve(["cwd": tree.path]) == Location(branch: "topic", worktree: true))
    }

    @Test func gitFileNotUnderWorktreesIsNoLocation() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let tree = try scratch.worktree("sub", branch: "topic", gitdirParent: "modules")
        #expect(resolve(["cwd": tree.path]) == nil)
    }

    @Test func detachedNotARepositoryAndHostilePathsAreNone() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let detached = try scratch.repo("detached", head: "0123456789abcdef0123456789abcdef01234567\n")
        #expect(resolve(["cwd": detached.path]) == nil)
        let plain = try scratch.directory("plain-dir")
        #expect(resolve(["cwd": plain.path]) == nil)
        #expect(resolve(["cwd": "relative/path"]) == nil)
        #expect(resolve(["cwd": "\u{0}/bad"]) == nil)
        #expect(resolve([:]) == nil)
        #expect(resolve(["cwd": 5]) == nil)
    }

    @Test func oversizedOrHostileGitEntriesAreNone() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let big = try scratch.repo("big", head: "ref: refs/heads/" + String(repeating: "a", count: 8_000) + "\n")
        #expect(resolve(["cwd": big.path]) == nil)
        let long = try scratch.repo("long", head: "ref: refs/heads/" + String(repeating: "a", count: 201) + "\n")
        #expect(resolve(["cwd": long.path]) == nil)
        let control = try scratch.repo("control", head: "ref: refs/heads/a\u{1}b\n")
        #expect(resolve(["cwd": control.path]) == nil)
        let empty = try scratch.repo("empty", head: "")
        #expect(resolve(["cwd": empty.path]) == nil)
        try scratch.write(String(repeating: "x", count: 9_000), "hugegit/.git")
        #expect(resolve(["cwd": scratch.root.appendingPathComponent("hugegit").path]) == nil)
        let outside = try scratch.directory("elsewhere")
        try scratch.write("gitdir: \(outside.path)\n", "badlink/.git")
        #expect(resolve(["cwd": scratch.root.appendingPathComponent("badlink").path]) == nil)
        try scratch.write("not a gitdir\n", "garbage/.git")
        #expect(resolve(["cwd": scratch.root.appendingPathComponent("garbage").path]) == nil)
    }

    @Test func symlinkedGitEntriesAreNeverFollowed() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let real = try scratch.repo("real")
        let linked = try scratch.directory("linked")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".git"),
                                                   withDestinationURL: real.appendingPathComponent(".git"))
        #expect(resolve(["cwd": linked.path]) == nil)
        let headLinked = try scratch.directory("headlinked/.git")
        try scratch.write("ref: refs/heads/stolen\n", "target-head")
        try FileManager.default.createSymbolicLink(at: headLinked.appendingPathComponent("HEAD"),
                                                   withDestinationURL: scratch.root.appendingPathComponent("target-head"))
        #expect(resolve(["cwd": scratch.root.appendingPathComponent("headlinked").path]) == nil)
    }

    @Test func toolPathBeatsCwdAndAcceptsObjectOrJSONStringArguments() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let first = try scratch.repo("first", head: "ref: refs/heads/one\n")
        let second = try scratch.repo("second", head: "ref: refs/heads/two\n")
        let file = second.appendingPathComponent("src/file.swift").path
        let object: [String: Any] = ["cwd": first.path, "toolName": "edit", "toolArgs": ["path": file]]
        #expect(resolve(object)?.branch == "two")
        let string: [String: Any] = ["cwd": first.path, "toolName": "view", "toolArgs": "{\"file_path\":\"\(file)\"}"]
        #expect(resolve(string)?.branch == "two")
        let camel: [String: Any] = ["cwd": first.path, "toolName": "create", "toolArgs": ["filePath": file]]
        #expect(resolve(camel)?.branch == "two")
        let relative: [String: Any] = ["cwd": first.path, "toolName": "edit", "toolArgs": ["path": "src/file.swift"]]
        #expect(resolve(relative)?.branch == "one")
        let broken: [String: Any] = ["cwd": first.path, "toolName": "edit", "toolArgs": "{not json"]
        #expect(resolve(broken)?.branch == "one")
        let newFile: [String: Any] = ["cwd": first.path, "toolName": "create",
                                      "toolArgs": ["path": second.appendingPathComponent("new/dir/x.txt").path]]
        #expect(resolve(newFile)?.branch == "two")
    }

    @Test func leadingChangeDirectoryParsing() {
        func cd(_ command: String) -> String? { Resolver.lastLeadingChange(command, home: "/Users/example") }
        #expect(cd("cd /a/b && make") == "/a/b")
        #expect(cd("cd /a && cd /b/c; ls") == "/b/c")
        #expect(cd("cd \"/with space\" && ls") == "/with space")
        #expect(cd("cd '/q' && ls") == "/q")
        #expect(cd("cd ~/code && ls") == "/Users/example/code")
        #expect(cd("  cd -P /p && ls") == "/p")
        #expect(cd("ls && cd /late") == nil)
        #expect(cd("cd /a && ls && cd /late") == "/a")
        #expect(cd("cd relative && ls") == nil)
        #expect(cd("cd /a && cd relative && ls") == "/a")
        #expect(cd("cd $HOME && ls") == nil)
        #expect(cd("cdx /a") == nil)
        #expect(cd("echo hi") == nil)
    }

    @Test func shellToolUsesLastLeadingChangeThenCwd() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let first = try scratch.repo("first", head: "ref: refs/heads/one\n")
        let second = try scratch.repo("second", head: "ref: refs/heads/two\n")
        let moved: [String: Any] = ["cwd": first.path, "toolName": "bash",
                                    "toolArgs": ["command": "cd \(second.path) && git status"]]
        #expect(resolve(moved)?.branch == "two")
        let stayed: [String: Any] = ["cwd": first.path, "toolName": "powershell", "toolArgs": ["command": "ls"]]
        #expect(resolve(stayed)?.branch == "one")
        let stringArgs: [String: Any] = ["cwd": first.path, "toolName": "bash",
                                         "toolArgs": "{\"command\":\"cd \(second.path) && ls\"}"]
        #expect(resolve(stringArgs)?.branch == "two")
    }

    @Test func locationRecordRoundTripsAndRejectsDeviations() throws {
        let session = UUID()
        let location = Location(branch: "topic", worktree: true)
        let data = try Location.encode(sessionID: session, location: location, recordedAt: Date(timeIntervalSince1970: 5))
        #expect(Location.decode(data, sessionID: session) == location)
        #expect(Location.decode(data, sessionID: UUID()) == nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/"+"Users"))
        for variant in [text.replacingOccurrences(of: "\"worktree\":true", with: "\"worktree\":1"),
                        text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                        text.dropLast() + ",\"extra\":1}", text.replacingOccurrences(of: "\"branch\":\"topic\",", with: "")] {
            #expect(Location.decode(Data(variant.utf8), sessionID: session) == nil)
        }
    }
}

struct CopilotLocationHookTests: Sendable {
    private let session = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let surface = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let workspace = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func lookup(_ pid: Int32) -> CMUXMaestroPreview.CopilotProcessLookup {
        switch pid {
        case 103: .found(.init(pid: 103, parentPID: 101, uid: getuid(), startSeconds: 3, startMicroseconds: 0))
        case 101: .found(.init(pid: 101, parentPID: 1, uid: getuid(), startSeconds: 1, startMicroseconds: 0))
        default: .dead
        }
    }

    private func run(_ scratch: LocationScratch, _ payload: [String: Any]) throws -> CMUXMaestroPreview.HookOutcome {
        let state = try scratch.directory("state/\(session.uuidString.lowercased())")
        try Data().write(to: state.appendingPathComponent("inuse.101.lock"))
        let recorder = CMUXMaestroPreview.CopilotHookRecorder(
            integrationRoot: scratch.root.appendingPathComponent("integration"),
            sessionStateRoot: scratch.root.appendingPathComponent("state"), processID: 103,
            process: { @Sendable pid in lookup(pid) }
        )
        var body = payload
        body["sessionId"] = session.uuidString
        return recorder.record(
            payload: try JSONSerialization.data(withJSONObject: body),
            environment: ["CMUX_SURFACE_ID": surface.uuidString, "CMUX_WORKSPACE_ID": workspace.uuidString]
        )
    }

    private func record(_ scratch: LocationScratch) -> URL {
        scratch.root.appendingPathComponent("integration/locations/\(session.uuidString.lowercased()).json")
    }

    @Test func publishesOnlyBranchAndWorktreeFlagPrivatelyAndClearsStaleRecords() throws {
        let scratch = try LocationScratch()
        let hook = try LocationScratch(underBuild: true)
        defer { scratch.remove(); hook.remove() }
        let repo = try scratch.repo("repo", head: "ref: refs/heads/topic\n")
        #expect(try run(hook, ["cwd": repo.path]) == .recorded)
        let file = record(hook)
        let data = try Data(contentsOf: file)
        #expect(CMUXMaestroPreview.CopilotSessionLocation.decode(data, sessionID: session) == .init(branch: "topic", worktree: false))
        #expect(!String(decoding: data, as: UTF8.self).contains(scratch.root.path))
        var info = stat()
        #expect(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(file.deletingLastPathComponent().path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let before = try Data(contentsOf: file)
        #expect(try run(hook, ["cwd": repo.path]) == .recorded)
        #expect(try Data(contentsOf: file) == before)
        let outside = try scratch.directory("not-a-repo")
        #expect(try run(hook, ["cwd": outside.path]) == .recorded)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let tree = try scratch.worktree("wt", branch: "w")
        #expect(try run(hook, ["cwd": tree.path]) == .recorded)
        #expect(CMUXMaestroPreview.CopilotSessionLocation.decode(try Data(contentsOf: file), sessionID: session)
            == .init(branch: "w", worktree: true))
    }
}
