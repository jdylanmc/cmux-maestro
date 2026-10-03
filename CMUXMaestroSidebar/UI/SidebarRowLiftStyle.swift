import Foundation

struct SidebarRowLiftStyle {
    static let highlightOpacity = 0.04
    static let nearShadowOpacity = 0.10
    static let farShadowOpacity = 0.06
    static let nearShadowRadius = 2.5
    static let farShadowRadius = 5.0
    static let nearShadowY = 1.0
    static let farShadowY = 4.0
    static let cornerRadius = 5.0
    static let duration = 0.160

    static func isLifted(eligible: Bool, hovered: Bool, keyboardFocused: Bool) -> Bool {
        eligible && (hovered || keyboardFocused)
    }
}
