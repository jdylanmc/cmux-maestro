import Darwin
import Foundation

@main
struct CopilotSandboxTestMain {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let allowed = root.appendingPathComponent("ancestor/deep/allowed", isDirectory: true)
        let orchestration = root.appendingPathComponent(
            "Library/Application Support/CMUXMaestroPreview/Orchestration",
            isDirectory: true
        )
        var failures = 0

        func check(_ label: String, _ operation: () throws -> Void) {
            do {
                try operation()
                print("PASS \(label)")
            } catch {
                failures += 1
                print("FAIL \(label) error=\(error as? CopilotFileError ?? .io)")
            }
            fflush(stdout)
        }

        func require(_ condition: Bool) throws {
            if !condition { throw CopilotFileError.io }
        }

        func denied(_ url: URL, flags: Int32) throws {
            let descriptor = Darwin.open(url.path, flags | O_CLOEXEC | O_NOFOLLOW)
            if descriptor >= 0 {
                close(descriptor)
                throw CopilotFileError.io
            }
            try require(errno == EACCES || errno == EPERM)
        }

        func readSample(at descriptor: Int32, expected: String) throws {
            let file = try CopilotFileAccess.openRegular(
                at: descriptor, name: "sample", owner: getuid(), permissions: 0o600
            )
            defer { close(file) }
            try require(try CopilotFileAccess.read(file, offset: 0, count: 64) == Data(expected.utf8))
        }

        check("direct authorized-file control") {
            let file = Darwin.open(allowed.appendingPathComponent("target/sample").path, O_RDONLY | O_NOFOLLOW)
            try require(file >= 0)
            close(file)
        }
        check("actual shared helper reads authorized deep directory") {
            let descriptor = try CopilotFileAccess.openDirectory(
                allowed.appendingPathComponent("target"), owner: getuid()
            )
            defer { close(descriptor) }
            try readSample(at: descriptor, expected: "ALLOWED")
            let names = try CopilotFileAccess.names(at: descriptor, limit: 1)
            try require(names.names.count == 1 && names.limited)
        }
        check("resumable stream reaches EOF and releases descriptors") {
            let descriptor = try CopilotFileAccess.openDirectory(
                allowed.appendingPathComponent("target"), owner: getuid()
            )
            defer { close(descriptor) }
            func descriptorCount() -> Int {
                (0..<1024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
            }
            let baseline = descriptorCount()
            for _ in 0..<128 {
                let stream = try CopilotDirectoryStream(at: descriptor)
                try require(try stream.next() != nil)
                // Partial streams close on destruction, without waiting for EOF.
            }
            try require(descriptorCount() == baseline)
            let stream = try CopilotDirectoryStream(at: descriptor)
            var names: Set<String> = []
            while let name = try stream.next() { names.insert(name) }
            try require(names == ["sample", "extra"] && stream.finished)
            try require(try stream.next() == nil)
            try require(descriptorCount() == baseline)
            stream.closeStream()
            stream.closeStream()
            try require(descriptorCount() == baseline)
        }
        check("ancestor directory contents denied") {
            try denied(root.appendingPathComponent("ancestor/deep"), flags: O_RDONLY | O_DIRECTORY)
        }
        check("ancestor file data denied") {
            try denied(root.appendingPathComponent("ancestor/private"), flags: O_RDONLY)
        }
        check("sibling file data denied") {
            try denied(root.appendingPathComponent("ancestor/deep/sibling/sample"), flags: O_RDONLY)
        }
        check("authorized subtree remains read-only") {
            try denied(allowed.appendingPathComponent("target/sample"), flags: O_WRONLY)
        }
        check("observer projection is readable through search-only ancestors") {
            let observer = try CopilotFileAccess.openDirectory(
                orchestration.appendingPathComponent("observer"), owner: getuid()
            )
            defer { close(observer) }
            let file = try CopilotFileAccess.openRegular(
                at: observer, name: "current.json", owner: getuid(), permissions: 0o600
            )
            defer { close(file) }
            try require(
                try CopilotFileAccess.read(file, offset: 0, count: 64)
                    == Data("{\"version\":1}\n".utf8)
            )
        }
        check("private orchestration siblings are denied") {
            for relative in ["control/state.json", "bin/controller", "tasks/prompt", "results/raw"] {
                try denied(orchestration.appendingPathComponent(relative), flags: O_RDONLY)
            }
        }
        check("orchestration ancestor cannot be listed") {
            try denied(orchestration, flags: O_RDONLY | O_DIRECTORY)
        }
        check("ancestor and sibling writes denied") {
            try denied(root.appendingPathComponent("ancestor/private"), flags: O_WRONLY)
            try denied(root.appendingPathComponent("ancestor/deep/sibling/sample"), flags: O_WRONLY)
        }
        check("search-only ancestor descriptor cannot list contents") {
            let directory = Darwin.open(
                root.appendingPathComponent("ancestor/deep").path,
                O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            try require(directory >= 0)
            defer { close(directory) }
            do {
                _ = try CopilotFileAccess.names(at: directory, limit: 1)
                throw CopilotFileError.io
            } catch CopilotFileError.permissionDenied {}
        }
        for name in ["ancestor-link/target", "target-link"] {
            check("shared helper rejects symlink \(name)") {
                do {
                    let descriptor = try CopilotFileAccess.openDirectory(
                        allowed.appendingPathComponent(name), owner: getuid()
                    )
                    close(descriptor)
                    throw CopilotFileError.io
                } catch CopilotFileError.unsafePath {}
            }
        }
        check("shared helper retains owner validation") {
            do {
                let descriptor = try CopilotFileAccess.openDirectory(
                    allowed.appendingPathComponent("target"), owner: getuid() &+ 1
                )
                close(descriptor)
                throw CopilotFileError.io
            } catch CopilotFileError.unsafePath {}
        }

        var anchored: Int32 = -1
        check("open descriptor before controlled path replacement") {
            anchored = try CopilotFileAccess.openDirectory(
                allowed.appendingPathComponent("anchored"), owner: getuid()
            )
        }
        print("READY_ANCHOR")
        fflush(stdout)
        guard readLine() == "continue" else { exit(2) }
        check("descriptor anchoring survives symlink replacement") {
            try require(anchored >= 0)
            let leaf = try CopilotFileAccess.openDirectory(at: anchored, name: "leaf", owner: getuid())
            defer { close(leaf) }
            try readSample(at: leaf, expected: "ORIGINAL")
        }
        if anchored >= 0 { close(anchored) }
        check("replaced absolute path is rejected rather than followed") {
            do {
                let descriptor = try CopilotFileAccess.openDirectory(
                    allowed.appendingPathComponent("anchored/leaf"), owner: getuid()
                )
                close(descriptor)
                throw CopilotFileError.io
            } catch CopilotFileError.unsafePath {}
        }

        print("READY_RACE")
        fflush(stdout)
        guard readLine() == "continue" else { exit(2) }
        check("bounded ancestor-swap race never reads redirected data") {
            for _ in 0..<512 {
                do {
                    let directory = try CopilotFileAccess.openDirectory(
                        allowed.appendingPathComponent("racing/leaf"), owner: getuid()
                    )
                    defer { close(directory) }
                    try readSample(at: directory, expected: "ORIGINAL")
                } catch CopilotFileError.unsafePath {
                } catch CopilotFileError.missing {
                }
            }
        }
        print("RESULT failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
