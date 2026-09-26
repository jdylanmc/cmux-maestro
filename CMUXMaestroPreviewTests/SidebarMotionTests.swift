import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarMotionTests {
    @Test func ringMakesOneLinearRevolutionAndReducedMotionHasNoPhaseChange() throws {
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.blocked), needsInput: true) == "Needs input. Blocked")
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.unknown)) == "Unknown")
        for (time, angle) in [(0.0, 0.0), (0.25, 90), (0.5, 180), (0.75, 270), (1, 0), (1.25, 90)] {
            let date = Date(timeIntervalSinceReferenceDate: time)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: false) == angle)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: true) == 0)
        }
    }

    @Test func nativeMotionAndStaticNegativeControlsStayInsideTheStatusLane() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, reduceMotion, needsInput) in [
            ("working", false, false), ("reduced-motion", true, false), ("needs-input", false, true)
        ] {
            let host = NSHostingView(rootView:
                HStack {
                    SidebarStateBadge(visual: SidebarPresentation.state(.working), needsInput: needsInput)
                    Text("Synthetic status").font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 5)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .background(SidebarActivityBackground(visual: SidebarPresentation.state(.working)))
                .background(Color.white)
            )
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let first = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame0.png"))
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let second = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame1.png"))
            #expect(!window.isVisible)
            let left = differences(first, second, columns: 0..<40)
            let rest = differences(first, second, columns: 40..<first.pixelsWide)
            #expect(rest == 0, "No row shimmer or text motion: \(name)")
            if name == "working" {
                #expect(left > 0, "The actual native working ring advances while hosted")
            } else {
                #expect(left == 0, "Static negative control: \(name)")
            }
            print("P57 native motion \(name): changedStatusPixels=\(left), changedOtherPixels=\(rest)")
        }
    }

    private func capture(_ view: NSView, to file: URL) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return bitmap
    }

    private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in columns {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
            }
        }
        return count
    }
}
