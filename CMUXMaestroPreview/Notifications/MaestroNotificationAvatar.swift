import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
struct MaestroNotificationAvatar {
    let catalog: SidebarGlyphCatalog

    func png(choice: SidebarIconChoice) throws -> Data {
        guard let outline = catalog.path(for: choice.glyph),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MaestroNotificationFailure.unavailable
        }
        let bounds = outline.boundingBoxOfPath
        let scale = min(192 / bounds.width, 192 / bounds.height)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: 128 - bounds.midX * scale, ty: 128 - bounds.midY * scale)
        guard let path = outline.copy(using: &transform) else { throw MaestroNotificationFailure.unavailable }
        context.addPath(path)
        context.setFillColor(choice.color.nativeColor.cgColor)
        if let custom = choice.color.customColor {
            context.setStrokeColor(custom.foreground.nativeColor.cgColor)
            context.setLineWidth(2)
            context.drawPath(using: .fillStroke)
        } else {
            context.fillPath()
        }
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MaestroNotificationFailure.unavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 262_144 else {
            throw MaestroNotificationFailure.unavailable
        }
        return output as Data
    }
}
