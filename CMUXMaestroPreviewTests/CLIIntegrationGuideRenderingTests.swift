import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import CMUXMaestroPreview

/// Hosted synthetic evidence only. Never reads installed guides or the general pasteboard.
@MainActor
@Suite(SidebarAppKitTestScope())
struct CLIIntegrationGuideRenderingTests {
    @Test func builtReferenceMatchesCanonicalSourceWithoutBundlingGlobalGuide() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reference = try #require(Bundle.main.url(forResource: "maestro-guide", withExtension: "sha256"))
        let canonical = try Data(contentsOf: root.appendingPathComponent("skills/maestro/SKILL.md"))
        let expected = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined() + "\n"
        #expect(try String(contentsOf: reference, encoding: .utf8) == expected)
        #expect(Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "maestro") == nil)
        #expect(Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "skills/maestro") == nil)
    }

    @Test func syntheticStatusesRetainNativeSizeScrollingAndAccessibleActions() async throws {
        let cases: [(String, CLIIntegrationGuideReader.Result)] = [
            ("missing", result(.missing)),
            ("unreadable", result(.unreadable(.permissionDenied))),
            ("different", result(.different)),
            ("matching", result(.matching)),
            ("reference-unavailable", .referenceUnavailable)
        ]
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, result) in cases {
            for dark in [false, true] {
                let model = CLIIntegrationGuideModel(read: { result })
                await model.recheck()
                var copies = 0
                let host = NSHostingView(rootView: CLIIntegrationSettingsView(model: model, copyCommand: {
                    copies += 1
                    return false
                }))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize == NSSize(width: 600, height: 350))
                #expect(copies == 0)
                let nodes = accessibilityNodes(host)
                let recheck = try #require(nodes.first { $0.accessibilityIdentifier() == "cli-integration-recheck" })
                #expect(recheck.accessibilityRole() == .button)
                #expect(recheck.isAccessibilityEnabled())
                if case .checked(let observations) = result {
                    for observation in observations {
                        let row = try #require(nodes.first {
                            $0.accessibilityIdentifier() == "cli-integration-status-" + observation.relativePath
                        })
                        #expect(row.isAccessibilityElement())
                    }
                } else {
                    #expect(nodes.contains { $0.accessibilityIdentifier() == "cli-integration-reference-error" })
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    folder.appendingPathComponent("cli-guide-\(name)-\(dark ? "dark" : "light").png"))
                let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                let document = try #require(scroll.documentView)
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
                document.scroll(NSPoint(x: 0, y: document.isFlipped
                    ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0))
                host.layoutSubtreeIfNeeded()
                let copy = try #require(accessibilityNodes(host).first {
                    $0.accessibilityIdentifier() == "cli-integration-copy-command"
                })
                #expect(copy.accessibilityRole() == .button)
                #expect(copy.isAccessibilityEnabled())
                #expect(copy.accessibilityPerformPress())
                #expect(copies == 1)
                #expect(model.copyNotice == "Could not copy the command. Select and copy the text above.")
            }
        }
    }

    private func result(_ content: CLIIntegrationGuideReader.Content) -> CLIIntegrationGuideReader.Result {
        .checked(CLIIntegrationGuideReader.relativePaths.map { .init(relativePath: $0, content: content) })
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func accessibilityNodes(_ root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        var nodes: [any NSAccessibilityProtocol] = []
        var pending: [any NSAccessibilityProtocol] = [root]
        var visited = Set<ObjectIdentifier>()
        while let node = pending.popLast(), nodes.count < 1_024 {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            nodes.append(node)
            pending += (node.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return nodes
    }
}
