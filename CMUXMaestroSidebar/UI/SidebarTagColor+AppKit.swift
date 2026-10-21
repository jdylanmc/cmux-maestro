import AppKit

extension SidebarTagColor {
    /// Convert wide-gamut and grayscale panel choices to opaque, bounded, 8-bit sRGB.
    init?(nativeColor: NSColor) {
        guard let rgb = nativeColor.usingColorSpace(.sRGB) else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard channels.allSatisfy(\.isFinite) else { return nil }
        func byte(_ channel: CGFloat) -> UInt8 { UInt8((min(1, max(0, channel)) * 255).rounded()) }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }

    var nativeColor: NSColor {
        NSColor(srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: 1)
    }
}
