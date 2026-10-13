import AppKit
import SwiftUI
import Testing

/// ADR 0019 oracle for copy-control text: the production field's label and value must match an independent
/// literal reference at native 2x, unshifted and with zero tolerance. Only the copy icon's exact bounds are
/// masked. The literal is placed so its value occupies the production value frame; a moved, substituted,
/// clipped or suffixed label then cannot match.
@MainActor
enum SidebarCopyFieldPixels {
    struct Result: CustomStringConvertible {
        let differing: Int
        let referenceInk: Int
        let region: CGRect
        var description: String { "differing=\(differing) referenceInk=\(referenceInk) region=\(region)" }
    }

    static func compare(
        in host: NSView, label: String, value: String, dark: Bool, destination: URL
    ) async throws -> Result {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let copyLabel = "Copy \(label.prefix(1).lowercased())\(label.dropFirst())"
        let button = try #require(views(host).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "hover-copy-value" && $0.accessibilityLabel() == copyLabel
        }, "Missing production copy control \(copyLabel)")
        let field = try #require(views(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == value },
                                 "Missing production value \(value)")
        let buttonRect = host.convert(button.bounds, from: button)
        let valueRect = host.convert(field.bounds, from: field)

        var placeholder = CGRect.null
        var literalFrame = CGRect.null
        func literal(leading: CGFloat, top: CGFloat) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 0) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 24, height: 24)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("literal-copy-field")) }
                            action: { placeholder = $0 }
                }
                .fixedSize(horizontal: true, vertical: false)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(width: valueRect.width, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("literal-copy-canvas")) }
                action: { literalFrame = $0 }
            .coordinateSpace(name: "literal-copy-field")
            .padding(.leading, leading).padding(.top, top)
            .frame(width: host.bounds.width, height: host.bounds.height, alignment: .topLeading)
            .coordinateSpace(name: "literal-copy-canvas")
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        }
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let reference = NSHostingView(rootView: literal(leading: 0, top: 0))
        window.contentView = reference
        defer { window.contentView = nil; window.close() }
        reference.frame = host.bounds
        func referenceValue() -> CGRect? {
            reference.layoutSubtreeIfNeeded()
            return views(reference).compactMap { $0 as? NSTextField }.first { $0.stringValue == value }
                .map { reference.convert($0.bounds, from: $0) }
        }
        await sidebarEventually { referenceValue() != nil && !placeholder.isNull }
        let unplaced = try #require(referenceValue())
        // Place the literal so its selectable value occupies the production value's exact frame; the label,
        // the copy slot and everything around them are then compared without any alignment search.
        let leading = valueRect.minX - unplaced.minX, top = valueRect.minY - unplaced.minY
        reference.rootView = literal(leading: leading, top: top)
        await sidebarEventually { referenceValue() == valueRect && abs(literalFrame.minX - leading) < 0.001 }
        try #require(referenceValue() == valueRect, "Literal value could not occupy the production value frame")
        reference.displayIfNeeded()
        #expect(!window.isVisible)

        let actual = try capture(host)
        let expected = try capture(reference)
        try #require(expected.representation(using: .png, properties: [:]))
            .write(to: destination.deletingPathExtension().appendingPathExtension("reference.png"))
        try #require(actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh)
        let scale = CGFloat(actual.pixelsWide) / host.bounds.width
        let points = CGRect(
            x: literalFrame.minX - 2, y: literalFrame.minY - 1,
            width: max(literalFrame.maxX, buttonRect.maxX) + 2 - (literalFrame.minX - 2),
            height: literalFrame.height + 2
        ).intersection(host.bounds)
        func pixels(_ rect: CGRect) -> CGRect {
            let flippedY = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            return CGRect(x: rect.minX * scale, y: flippedY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        let region = pixels(points).integral
        let mask = pixels(buttonRect)
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
        let result = Result(differing: differing, referenceInk: ink, region: region)
        try JSONSerialization.data(withJSONObject: [
            "differingPixels": differing, "referenceInkPixels": ink, "tolerance": 0, "alignmentPixels": [0, 0],
            "regionPixels": [region.minX, region.minY, region.width, region.height],
            "maskedCopyIconPixels": [mask.minX, mask.minY, mask.width, mask.height]
        ], options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.deletingPathExtension().appendingPathExtension("copy-pixels.json"))
        return result
    }

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
