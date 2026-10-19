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
        _ = try directory("\(name)/.git/objects")
        _ = try directory("\(name)/.git/refs")
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

    private func run(
        _ scratch: LocationScratch, _ payload: [String: Any], workspaceYAML: String? = nil
    ) throws -> CMUXMaestroPreview.HookOutcome {
        let state = try scratch.directory("state/\(session.uuidString.lowercased())")
        if let workspaceYAML { try Data(workspaceYAML.utf8).write(to: state.appendingPathComponent("workspace.yaml")) }
        try Data().write(to: state.appendingPathComponent("inuse.101.lock"))
        let recorder = CMUXMaestroPreview.CopilotHookRecorder(
            integrationRoot: scratch.root.appendingPathComponent("integration"),
            sessionStateRoot: scratch.root.appendingPathComponent("state"), processID: 103,
            process: { @Sendable pid in lookup(pid) }
        )
        var body = payload
        body["sessionId"] = session.uuidString
        return recorder.bind(
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
        #expect(CMUXMaestroPreview.CopilotSessionLocationRecord.decode(data, sessionID: session)?.location == .init(branch: "topic", worktree: false))
        #expect(!String(decoding: data, as: UTF8.self).contains(scratch.root.path))
        var info = stat()
        #expect(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(file.deletingLastPathComponent().path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let before = try Data(contentsOf: file)
        #expect(try run(hook, ["cwd": repo.path]) == .recorded)
        #expect(try Data(contentsOf: file) == before)
        let outside = try scratch.directory("not-a-repo")
        #expect(try run(hook, ["cwd": outside.path]) == .recorded)
        // The record stays for the session's current worktree; the tool-path branch fact is gone.
        #expect(CMUXMaestroPreview.CopilotSessionLocationRecord.decode(try Data(contentsOf: file), sessionID: session)?
            .location == nil)
        let tree = try scratch.worktree("wt", branch: "w")
        #expect(try run(hook, ["cwd": tree.path]) == .recorded)
        #expect(CMUXMaestroPreview.CopilotSessionLocationRecord.decode(try Data(contentsOf: file), sessionID: session)?
            .location == .init(branch: "w", worktree: true))
    }

    /// The session's own selected directory decides its worktree, not the tool path or payload cwd.
    @Test func publishesCurrentWorktreeFromTheSessionSelectedDirectory() throws {
        let scratch = try LocationScratch()
        let hook = try LocationScratch(underBuild: true)
        defer { scratch.remove(); hook.remove() }
        let repo = try scratch.repo("repo", head: "ref: refs/heads/main\n")
        let first = try WorktreeFixture.linked(scratch, repository: "repo", name: "first", branch: "topic")
        let second = try WorktreeFixture.linked(scratch, repository: "repo", name: "second", branch: "topic")
        func current() throws -> CMUXMaestroPreview.CopilotSessionWorktree? {
            CMUXMaestroPreview.CopilotSessionLocationRecord.decode(try Data(contentsOf: record(hook)), sessionID: session)?.current
        }
        #expect(try run(hook, ["cwd": repo.path], workspaceYAML: "id: x\ncwd: \(first.path)\n") == .recorded)
        guard case .verified(let one) = try current()?.evidence else { Issue.record("not verified"); return }
        #expect(one.repository == "repo" && one.head == .branch("topic") && one.linked)
        #expect(try current()?.source != nil)
        #expect(try run(hook, ["cwd": repo.path], workspaceYAML: "id: x\ncwd: \(second.path)\n") == .recorded)
        guard case .verified(let two) = try current()?.evidence else { Issue.record("not verified"); return }
        #expect(two.key != one.key && two.repository == one.repository && two.head == one.head)
        let text = String(decoding: try Data(contentsOf: record(hook)), as: UTF8.self)
        #expect(!text.contains(scratch.root.path))
        #expect(try run(hook, ["cwd": repo.path], workspaceYAML: "id: x\n") == .recorded)
        #expect(try current()?.evidence == .unknown)
        try FileManager.default.removeItem(
            at: hook.root.appendingPathComponent("state/\(session.uuidString.lowercased())/workspace.yaml"))
        #expect(try run(hook, ["cwd": repo.path]) == .recorded)
        #expect(try current() == .init(evidence: .unknown, source: nil))
    }
}

private enum WorktreeFixture {
    /// `git worktree add` layout: a `.git` file naming the private Git directory, which names the common one.
    static func linked(_ scratch: LocationScratch, repository: String, name: String, branch: String? = nil,
                       detached: String? = nil) throws -> URL {
        let admin = "\(repository)/.git/worktrees/\(name)"
        try scratch.write(branch.map { "ref: refs/heads/\($0)\n" } ?? "\(detached ?? "")\n", "\(admin)/HEAD")
        try scratch.write("../..\n", "\(admin)/commondir")
        try scratch.write("gitdir: \(scratch.root.path)/\(admin)\n", "\(name)/.git")
        try scratch.write("", "\(name)/src/file.swift")
        return scratch.root.appendingPathComponent(name)
    }
}

struct CopilotWorktreeResolverTests: Sendable {
    private typealias Evidence = CMUXMaestroPreview.CopilotWorktreeEvidence
    private func resolve(_ url: URL) -> Evidence { CMUXMaestroPreview.CopilotWorktreeResolver.resolve(directory: url.path) }
    private func identity(_ url: URL) -> CMUXMaestroPreview.CopilotWorktreeIdentity? {
        if case .verified(let identity) = resolve(url) { return identity }
        return nil
    }

    @Test func worktreesOfOneRepositoryAtOneCommitStayDistinct() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let main = try scratch.repo("repo", head: "\(commit)\n")
        let left = try WorktreeFixture.linked(scratch, repository: "repo", name: "left", detached: commit)
        let right = try WorktreeFixture.linked(scratch, repository: "repo", name: "right", branch: "topic")
        let mainID = try #require(identity(main))
        let leftID = try #require(identity(left))
        let rightID = try #require(identity(right))
        #expect(Set([mainID.key, leftID.key, rightID.key]).count == 3)
        #expect([mainID, leftID, rightID].allSatisfy { $0.repository == "repo" })
        #expect(mainID.head == .detached("0123456") && !mainID.linked)
        #expect(leftID.head == .detached("0123456") && leftID.linked)
        #expect(rightID.head == .branch("topic") && rightID.linked)
        // Nested directories and a later branch change keep the worktree's key.
        #expect(identity(right.appendingPathComponent("src"))?.key == rightID.key)
        try scratch.write("ref: refs/heads/other\n", "repo/.git/worktrees/right/HEAD")
        #expect(identity(right)?.key == rightID.key && identity(right)?.head == .branch("other"))
    }

    @Test func sameNameAndBranchInDifferentRepositoriesStayDistinct() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let one = try scratch.repo("a/app")
        let two = try scratch.repo("b/app")
        #expect(identity(one)?.repository == "app" && identity(two)?.repository == "app")
        #expect(identity(one)?.key != identity(two)?.key)
    }

    @Test func onlyAReadableWalkToRootProvesNoRepository() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let plain = try scratch.directory("plain/deeper")
        #expect(resolve(plain) == .nonRepository)
        #expect(resolve(scratch.root.appendingPathComponent("missing")) == .unknown)
        #expect(CMUXMaestroPreview.CopilotWorktreeResolver.resolve(directory: "relative") == .unknown)
        // A bare repository or a Git administrative directory is unsupported, never "no repository".
        try scratch.write("ref: refs/heads/main\n", "bare.git/HEAD")
        _ = try scratch.directory("bare.git/objects")
        _ = try scratch.directory("bare.git/refs")
        #expect(resolve(scratch.root.appendingPathComponent("bare.git")) == .unknown)
        let repo = try scratch.repo("repo")
        #expect(resolve(repo.appendingPathComponent(".git")) == .unknown)
        // Malformed or symlinked Git entries are unknown.
        try scratch.write("garbage\n", "garbage/.git")
        #expect(resolve(scratch.root.appendingPathComponent("garbage")) == .unknown)
        let broken = try scratch.repo("broken", head: "ref: refs/remotes/origin/main\n")
        #expect(resolve(broken) == .unknown)
        let linked = try scratch.directory("linked")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".git"),
                                                   withDestinationURL: repo.appendingPathComponent(".git"))
        #expect(resolve(linked) == .unknown)
        // Denied traversal proves nothing.
        let denied = try scratch.directory("denied/inner")
        chmod(scratch.root.appendingPathComponent("denied").path, 0o000)
        defer { chmod(scratch.root.appendingPathComponent("denied").path, 0o755) }
        #expect(resolve(denied) == .unknown)
    }

    /// A quoted `cwd:` keeps its escaped tab; only name display turns it into a space.
    @Test func escapedTabInCwdNamesTheTabbedDirectoryNotItsSpacedSibling() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let tabbed = try scratch.repo("a\tb")
        let spaced = try scratch.repo("a b")
        let yaml = Data("name: \"x\\ty\"\ncwd: \"\(scratch.root.path)/a\\tb\"\n".utf8)
        let cwd = try #require(CMUXMaestroPreview.CopilotSessionName.scalar(forKey: "cwd", in: yaml))
        #expect(cwd == tabbed.path)
        #expect(CMUXMaestroPreview.CopilotWorktreeResolver.resolve(directory: cwd) == resolve(tabbed))
        #expect(resolve(tabbed) != resolve(spaced))
        #expect(CMUXMaestroPreview.CopilotSessionName.parse(yaml) == "x y")
    }

    /// Git keeps spaces in a gitfile path and drops only trailing CR/LF; so does the resolver.
    @Test func gitfilePathKeepsTrailingSpacesLikeGit() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        for (directory, branch) in [("admin ", "spaced"), ("admin", "sibling")] {
            try scratch.write("ref: refs/heads/\(branch)\n", "\(directory)/HEAD")
            _ = try scratch.directory("\(directory)/objects")
            _ = try scratch.directory("\(directory)/refs")
        }
        try scratch.write("gitdir: \(scratch.root.path)/admin \r\n", "tree/.git")
        guard case .verified(let tree) = resolve(scratch.root.appendingPathComponent("tree")) else {
            Issue.record("gitfile with a trailing-space path must verify that directory"); return
        }
        #expect(tree.head == .branch("spaced"))
        try scratch.write("gitdir: \(scratch.root.path)/admin\n", "other/.git")
        guard case .verified(let other) = resolve(scratch.root.appendingPathComponent("other")) else {
            Issue.record("control gitfile must verify"); return
        }
        #expect(other.head == .branch("sibling") && other.key != tree.key)
        // Without the exact `gitdir: ` prefix, Git refuses the file; so do we.
        try scratch.write("gitdir:\(scratch.root.path)/admin\n", "loose/.git")
        #expect(resolve(scratch.root.appendingPathComponent("loose")) == .unknown)
        #expect(CMUXMaestroPreview.CopilotWorktreeResolver.gitPathFile("a b \t\r\n\n") == "a b \t")
        #expect(CMUXMaestroPreview.CopilotWorktreeResolver.gitPathFile("a\nb\n") == nil)
    }

    /// YAML blanks are ASCII space and tab; a trailing NBSP is part of the path.
    @Test func trailingNoBreakSpaceInCwdStaysInThePath() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        let plain = try scratch.repo("app")
        let spaced = try scratch.repo("app\u{00A0}")
        let yaml = Data("name: Synthetic\u{00A0}\ncwd: \(spaced.path)\n".utf8)
        let cwd = try #require(CMUXMaestroPreview.CopilotSessionName.scalar(forKey: "cwd", in: yaml))
        #expect(cwd == spaced.path)
        #expect(CMUXMaestroPreview.CopilotWorktreeResolver.resolve(directory: cwd) == resolve(spaced))
        #expect(resolve(spaced) != resolve(plain))
        #expect(CMUXMaestroPreview.CopilotSessionName.parse(yaml) == "Synthetic")
    }

    /// Git's repository test: the shared Git directory must hold `objects` and `refs`.
    @Test func headOnlyGitDirectoriesAreUnknown() throws {
        let scratch = try LocationScratch()
        defer { scratch.remove() }
        try scratch.write("ref: refs/heads/main\n", "bare-head/.git/HEAD")
        #expect(resolve(scratch.root.appendingPathComponent("bare-head")) == .unknown)
        try scratch.write("ref: refs/heads/main\n", "target/HEAD")
        try scratch.write("gitdir: \(scratch.root.path)/target\n", "gitfile/.git")
        #expect(resolve(scratch.root.appendingPathComponent("gitfile")) == .unknown)
        _ = try scratch.directory("plain-common")
        try scratch.write("ref: refs/heads/main\n", "admin/HEAD")
        try scratch.write("../plain-common\n", "admin/commondir")
        try scratch.write("gitdir: \(scratch.root.path)/admin\n", "linked/.git")
        #expect(resolve(scratch.root.appendingPathComponent("linked")) == .unknown)
        // Control: the same linked layout with a real shared directory verifies.
        _ = try scratch.directory("plain-common/objects")
        _ = try scratch.directory("plain-common/refs")
        guard case .verified = resolve(scratch.root.appendingPathComponent("linked")) else {
            Issue.record("control must verify"); return
        }
    }

    @Test func headIsReadAsGitReadsIt() {
        let parse = CMUXMaestroPreview.CopilotWorktreeResolver.parseHead
        #expect(parse("ref: refs/heads/topic \n") == .branch("topic"))
        #expect(parse("ref: refs/heads/a..b\n") == nil)
        #expect(parse("\nref: refs/heads/main\n") == nil)
        #expect(parse("ref: refs/heads/main\njunk\n") == nil)
        for bad in ["a@{b", "a.lock", ".hidden", "a/.b", "a b", "a~1", "a^", "a:b", "a?", "a*", "a[", "a\\b", "a/", "a.", "@", "-a", "a//b"] {
            #expect(parse("ref: refs/heads/\(bad)\n") == nil, "\(bad)")
        }
        #expect(parse("ref: refs/heads/feat/x-1.2\n") == .branch("feat/x-1.2"))
        #expect(parse("0123456789abcdef0123456789abcdef01234567\n") == .detached("0123456"))
    }

    @Test func currentWorktreeRecordRoundTripsAndRejectsDeviations() throws {
        let session = UUID()
        let identity = CMUXMaestroPreview.CopilotWorktreeIdentity(
            key: "0123456789abcdef", repository: "repo", head: .branch("topic"), linked: true
        )
        let source = CMUXMaestroPreview.CopilotWorktreeSource(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5)
        let current = CMUXMaestroPreview.CopilotSessionWorktree(evidence: .verified(identity), source: source)
        let data = try Location.encode(sessionID: session, location: nil, current: current, recordedAt: Date(timeIntervalSince1970: 5))
        #expect(CMUXMaestroPreview.CopilotSessionLocationRecord.decode(data, sessionID: session)
            == .init(location: nil, current: current))
        #expect(Location.decode(data, sessionID: session) == nil)
        let text = String(decoding: data, as: UTF8.self)
        for variant in [text.replacingOccurrences(of: "\"linked\":true", with: "\"linked\":1"),
                        text.replacingOccurrences(of: "0123456789abcdef", with: "0123456789ABCDEF"),
                        text.replacingOccurrences(of: "\"status\":\"verified\"", with: "\"status\":\"maybe\""),
                        text.replacingOccurrences(of: "\"repository\":\"repo\"", with: "\"repository\":\"a/b\""),
                        text.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":3"),
                        text.dropLast() + ",\"path\":\"/x\"}"] {
            #expect(CMUXMaestroPreview.CopilotSessionLocationRecord.decode(Data(variant.utf8), sessionID: session) == nil)
        }
        let unknown = try Location.encode(sessionID: session, location: .init(branch: "b", worktree: false),
                                          current: .init(evidence: .unknown, source: nil), recordedAt: Date())
        #expect(CMUXMaestroPreview.CopilotSessionLocationRecord.decode(unknown, sessionID: session)
            == .init(location: .init(branch: "b", worktree: false), current: .init(evidence: .unknown, source: nil)))
    }
}
