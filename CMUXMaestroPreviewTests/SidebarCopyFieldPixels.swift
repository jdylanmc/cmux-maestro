import AppKit
import SwiftUI
import Testing

/// ADR 0019 oracle for copy-control text in a preview card. An independent literal card (same chrome
/// constants, literal label and value, an empty 24-point slot for the copy icon) is laid out in a host of
/// the same predetermined size and origin as the production card. Nothing is aligned to measured production
/// geometry: the expected value frame comes from the literal, the production frame is checked against it,
/// and pixels are compared unshifted with zero tolerance, masking only the literal copy-icon slot.
@MainActor
enum SidebarCopyFieldPixels {
    struct Result: CustomStringConvertible {
        let expectedValueFrame: CGRect
        let actualValueFrame: CGRect?
        let differing: Int
        let referenceInk: Int
        let region: CGRect
        var valueFrameMatches: Bool { actualValueFrame == expectedValueFrame }
        var description: String {
            "expectedValue=\(expectedValueFrame) actualValue=\(String(describing: actualValueFrame)) "
                + "differing=\(differing) referenceInk=\(referenceInk) region=\(region)"
        }
    }

    /// `production` must host a `SidebarHoverCard` whose only line is the copyable `label`/`value`.
    static func compareCard(
        _ production: NSView, category: String, title: String, label: String, value: String,
        dark: Bool, destination: URL
    ) async throws -> Result {
        var slot = CGRect.null
        var field = CGRect.null
        let literal = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(category).font(.caption).foregroundStyle(.secondary)
                    Text(title).font(.headline).lineLimit(3)
                }
                Spacer(minLength: 0)
                Color.clear.frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 0) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 24, height: 24)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("literal-card")) } action: { slot = $0 }
                }
                .fixedSize(horizontal: true, vertical: false)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("literal-card")) } action: { field = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "literal-card")
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor))

        let window = NSWindow(contentRect: production.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let reference = NSHostingView(rootView: literal)
        window.contentView = reference
        defer { window.contentView = nil; window.close() }
        reference.frame = production.bounds
        func valueFrame(in host: NSView) -> CGRect? {
            host.layoutSubtreeIfNeeded()
            return views(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == value }
                .map { host.convert($0.bounds, from: $0) }
        }
        await sidebarEventually { valueFrame(in: reference) != nil && !slot.isNull && !field.isNull }
        let expectedValue = try #require(valueFrame(in: reference))
        reference.displayIfNeeded()
        #expect(!window.isVisible)

        let actual = try capture(production)
        let expected = try capture(reference)
        try #require(expected.representation(using: .png, properties: [:]))
            .write(to: destination.deletingPathExtension().appendingPathExtension("reference.png"))
        try #require(actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh)
        let scale = CGFloat(actual.pixelsWide) / production.bounds.width
        func pixels(_ rect: CGRect) -> CGRect {
            let flippedY = reference.isFlipped ? rect.minY : reference.bounds.height - rect.maxY
            return CGRect(x: rect.minX * scale, y: flippedY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        // The whole literal field row plus a border, out to the card's trailing padding: suffix ink must fail.
        let points = CGRect(x: field.minX - 2, y: field.minY - 2,
                            width: reference.bounds.width - 14 + 2 - (field.minX - 2), height: field.height + 4)
            .intersection(reference.bounds)
        let region = pixels(points).integral
        let mask = pixels(slot)
        let background = try #require(expected.colorAt(x: Int(region.minX), y: Int(region.minY))?
            .usingColorSpace(.deviceRGB))
        var differing = 0, ink = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX)
            where !mask.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                let a = try #require(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let e = try #require(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(abs(a.redComponent - e.redComponent), abs(a.greenComponent - e.greenComponent),
                       abs(a.blueComponent - e.blueComponent), abs(a.alphaComponent - e.alphaComponent)) > 0 {
                    differing += 1
                }
                if max(abs(background.redComponent - e.redComponent), abs(background.greenComponent - e.greenComponent),
                       abs(background.blueComponent - e.blueComponent)) > 0.1 {
                    ink += 1
                }
            }
        }
        let result = Result(expectedValueFrame: expectedValue, actualValueFrame: valueFrame(in: production),
                            differing: differing, referenceInk: ink, region: region)
        try JSONSerialization.data(withJSONObject: [
            "differingPixels": differing, "referenceInkPixels": ink, "tolerance": 0, "alignmentPixels": [0, 0],
            "valueFrameMatches": result.valueFrameMatches,
            "regionPixels": [region.minX, region.minY, region.width, region.height],
            "maskedCopyIconPixels": [mask.minX, mask.minY, mask.width, mask.height]
        ], options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.deletingPathExtension().appendingPathExtension("copy-pixels.json"))
        return result
    }

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private static func capture(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
