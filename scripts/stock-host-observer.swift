// Hosted probe only: observe, never host an extension or synthesize input.
import AppKit
import CoreGraphics
import ExtensionFoundation
import Foundation

@main
struct StockHostObserver {
    @MainActor static func emit(_ value: [String: Any]) {
        var row = value
        row["time"] = Date().timeIntervalSince1970
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              NSHomeDirectory() == "/Users/runner" else {
            throw NSError(domain: "HostedOnly", code: 1)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 3, args[0] == "quit", let pid = Int32(args[1]) {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == "com.cmuxterm.app",
                  app.bundleURL?.standardizedFileURL.path == args[2],
                  app.terminate() else {
                throw NSError(domain: "ExactHostQuitRefused", code: 1)
            }
            return
        }
        if args.count == 3, args[0] == "inspect", let pid = Int32(args[1]) {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == "com.cmuxterm.app",
                  app.bundleURL?.standardizedFileURL.path == args[2] else {
                throw NSError(domain: "ExactHostInspectionRefused", code: 1)
            }
            let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let owned = windows.filter {
                Int32($0[kCGWindowOwnerPID as String] as? Int ?? -1) == pid
            }.prefix(8).map { window -> [String: Any] in
                [
                    "id": window[kCGWindowNumber as String] as? Int ?? -1,
                    "layer": window[kCGWindowLayer as String] as? Int ?? -1,
                    "onscreen": window[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    "title": window[kCGWindowName as String] as? String ?? "(unavailable)",
                    "bounds": window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                ]
            }
            emit(["kind": "stock-ui", "pid": pid, "bundlePath": args[2],
                  "active": app.isActive, "hidden": app.isHidden, "windows": owned])
            return
        }
        guard args == ["watch"] else { throw NSError(domain: "Usage", code: 1) }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              bundleIdentifier == "com.jdylanmc.CMUXMaestroPreview.HostProofObserver",
              Bundle.main.bundleURL.pathExtension == "app" else {
            throw NSError(domain: "ObserverBundleIdentityMissing", code: 1)
        }
        emit(["kind": "observer-context",
              "bundleIdentifier": bundleIdentifier,
              "bundlePath": Bundle.main.bundleURL.path,
              "extensionPoint": "com.cmuxterm.app.cmux.sidebar",
              "role": "discovery only; no extension launch or XPC connection"])
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier ?? -1
            Task { @MainActor in emit(["kind": "activation", "pid": pid]) }
        }
        defer { center.removeObserver(token) }
        let identities = Task { @MainActor in
            do {
                for await values in try AppExtensionIdentity.matching(
                    appExtensionPointIDs: "com.cmuxterm.app.cmux.sidebar"
                ) {
                    emit(["kind": "identities", "ids": values.map(\.bundleIdentifier).sorted()])
                }
            } catch {
                let diagnostic = error as NSError
                emit(["kind": "observer-error", "error": String(describing: error),
                      "domain": diagnostic.domain, "code": diagnostic.code,
                      "description": diagnostic.localizedDescription,
                      "failureReason": diagnostic.localizedFailureReason ?? "not supplied"])
            }
        }
        defer { identities.cancel() }
        for _ in 0..<8400 {
            let hosts = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == "com.cmuxterm.app"
            }
            let pids = hosts.map(\.processIdentifier)
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let visible = windows.filter {
                pids.contains(Int32($0[kCGWindowOwnerPID as String] as? Int ?? -1)) &&
                    ($0[kCGWindowLayer as String] as? Int) == 0
            }.compactMap { $0[kCGWindowNumber as String] as? Int }.sorted()
            emit(["kind": "sample",
                  "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                  "hostPIDs": pids, "visibleWindows": visible])
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
