import SwiftUI

/// The system color well is controlled by its owner, just like the named swatches.
struct SidebarCustomColorPicker: View {
    let color: NSColor
    var selected: SidebarTagColor?
    let choose: (SidebarTagColor) -> Void
    @State private var unavailable = false
    private var title: String { String(localized: "color.custom", defaultValue: "Custom…") }

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker(selection: Binding(
                get: { Color(nsColor: color) },
                set: { value in
                    guard let rgb = SidebarTagColor(nativeColor: NSColor(value)) else {
                        unavailable = true
                        return
                    }
                    unavailable = false
                    choose(rgb)
                }
            ), supportsOpacity: false) {
                Text(title)
            }
            .accessibilityLabel(selected.map { "\(title) \($0.hex)" } ?? title)
            .accessibilityValue(selected?.hex ?? "")
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
