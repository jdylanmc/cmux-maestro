import AppKit
import SwiftUI
import Testing
@testable import CMUXMaestroPreview

/// Offscreen synthetic Settings evidence, not a live-host or VoiceOver session.
@MainActor
@Suite(.serialized)
struct CLIIntegrationRenderingTests {
    @Test func guideStatesRenderSeparatelyInNarrowAndStandardSettings() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for states in [[CLIIntegrationGuideStatus.matching, .different], [.missing, .unreadable]] {
            let inspections = zip(CLIIntegrationGuideLocation.allCases, states).map {
                CLIIntegrationGuideInspection(
                    location: $0, status: $1,
                    detail: $1 == .unreadable
                        ? "Cannot safely read both guide files. Check access and regular file types; symlinks are not followed."
                        : "Synthetic evidence for this location only."
                )
            }
            for width in [360, 600] {
                for dark in [false, true] {
                    let model = CLIIntegrationGuideCheck(inspections: inspections, read: { inspections })
                    let frame = NSRect(x: 0, y: 0, width: width, height: 640)
                    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let view = NSHostingView(rootView: CLIIntegrationSettingsView(check: model))
                    window.contentView = view
                    defer { window.contentView = nil; window.close() }
                    view.frame = frame
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                    view.layoutSubtreeIfNeeded()
                    #expect(!window.isVisible)
                    let metrics = SidebarRenderingEvidence.metrics(for: view)
                    #expect(metrics.viewportWidth > 0)
                    #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
                    let destination = output.appendingPathComponent(
                        "cli-guide-\(states[0].rawValue)-\(width)-\(dark ? "dark" : "light").png"
                    )
                    let bitmap = try #require(NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: 1280,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                    ))
                    bitmap.size = view.bounds.size
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
                    let words = try SidebarRenderingEvidence.recognizedLines(in: destination, dark: dark).joined(separator: " ")
                    for state in states { #expect(words.contains(state.title), "\(state.title) not rendered: \(words)") }
                    #expect(words.contains("Copilot copy location"))
                    #expect(words.contains("Legacy guide location"))
                    try JSONEncoder().encode(metrics).write(
                        to: destination.deletingPathExtension().appendingPathExtension("json")
                    )
                }
            }
        }
    }

}
