import SwiftUI

/// The native well previews continuously and commits once when the system panel closes.
struct SidebarCustomColorPicker: View {
    let color: NSColor
    var selected: SidebarTagColor?
    let choose: (SidebarTagColor) -> Void
    @State private var unavailable = false
    private var title: String { String(localized: "color.custom", defaultValue: "Custom…") }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            SidebarColorWell(
                color: color, label: selected.map { "\(title) \($0.hex)" } ?? title,
                choose: choose, unavailable: { unavailable = $0 }
            )
            .frame(width: 44, height: 24)
            .accessibilityAddTraits(selected == nil ? [] : .isSelected)
            if selected != nil {
                Image(systemName: "checkmark").font(.caption).accessibilityHidden(true)
            }
            if unavailable {
                Label(String(localized: "color.unavailable", defaultValue: "Color unavailable"),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
        }
        .accessibilityIdentifier("sidebar-custom-color")
    }
}
