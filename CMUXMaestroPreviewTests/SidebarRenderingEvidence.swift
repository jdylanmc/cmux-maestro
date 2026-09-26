import AppKit
import Vision

@MainActor
enum SidebarRenderingEvidence {
    struct Metrics: Codable {
        let width: Double
        let height: Double
        let viewportWidth: Double
        let viewportHeight: Double
        let documentWidth: Double
        let documentHeight: Double
        let visibleHostWindows: Int
    }

    static func metrics(for view: NSView) -> Metrics {
        var scrollViews: [NSScrollView] = []
        func visit(_ child: NSView) {
            if let scroll = child as? NSScrollView { scrollViews.append(scroll) }
            child.subviews.forEach(visit)
        }

        visit(view)
        let scroll = scrollViews.max { $0.bounds.height < $1.bounds.height }
        return Metrics(
            width: view.bounds.width, height: view.bounds.height,
            viewportWidth: Double(scroll?.contentView.bounds.width ?? 0),
            viewportHeight: Double(scroll?.contentView.bounds.height ?? 0),
            documentWidth: Double(scroll?.documentView?.bounds.width ?? 0),
            documentHeight: Double(scroll?.documentView?.bounds.height ?? 0),
            visibleHostWindows: NSApp.windows.filter(\.isVisible).count
        )
    }

    static func recognizedLines(
        in image: URL, dark: Bool = false, excludingLeadingFraction: CGFloat = 0,
        naturalLanguage: Bool = false
    ) throws -> [String] {
        guard let raw = NSBitmapImageRep(data: try Data(contentsOf: image))?.cgImage else {
            throw ImageInspectionError.decodeFailed
        }
        let inset = floor(CGFloat(raw.width) * excludingLeadingFraction)
        guard inset >= 0, inset < CGFloat(raw.width),
              let source = raw.cropping(to: CGRect(
                x: inset, y: 0, width: CGFloat(raw.width) - inset, height: CGFloat(raw.height)
              )) else { throw ImageInspectionError.decodeFailed }
        // Hosted Macs capture at 1x. Give OCR the same legible input scale without changing the render.
        let scale = max(1, (1_020 + source.width - 1) / source.width)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: source.width * scale, height: source.height * scale,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ImageInspectionError.scaleFailed }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: 0, y: 0, width: source.width * scale, height: source.height * scale
        ))
        if dark {
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: source.width * scale, height: source.height * scale))
        }
        guard let legible = context.makeImage() else { throw ImageInspectionError.scaleFailed }
        return try recognize(legible, naturalLanguage: naturalLanguage)
    }

    static func recognizedNativeLines(in image: URL) throws -> [String] {
        guard let source = NSBitmapImageRep(data: try Data(contentsOf: image))?.cgImage else {
            throw ImageInspectionError.decodeFailed
        }
        // Already rasterized at an explicit native scale; do not resample the glyphs for OCR.
        return try recognize(source, naturalLanguage: false)
    }

    private static func recognize(_ image: CGImage, naturalLanguage: Bool) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = naturalLanguage
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private enum ImageInspectionError: Error {
        case decodeFailed, scaleFailed
    }
}
