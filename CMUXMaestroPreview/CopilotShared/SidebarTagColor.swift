import Foundation

nonisolated struct SidebarTagColor: Hashable, Sendable {
    let red: UInt8, green: UInt8, blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Opaque sRGB only; no shorthand, whitespace, alpha, or non-ASCII digits.
    init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// WCAG 2 relative luminance.
    var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 255, green: 255, blue: 255)

    static func contrast(_ first: Self, _ second: Self) -> Double {
        let (a, b) = (first.luminance, second.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Black or white, whichever contrasts more with this background.
    var foreground: Self {
        Self.contrast(.black, self) >= Self.contrast(.white, self) ? .black : .white
    }
}
