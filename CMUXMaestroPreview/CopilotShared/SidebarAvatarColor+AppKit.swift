import AppKit

extension SidebarAvatarColor {
    var nativeColor: NSColor {
        switch self {
        case .theme: .labelColor
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .gray: .systemGray
        case .custom(let color): color.nativeColor
        }
    }
}
