import SwiftUI

/// Sidebar-only adapter; the picker itself knows nothing about sessions or storage.
struct SidebarItemIcon: View {
    enum Kind { case agent, terminal, browser }
    let kind: Kind
    let target: SidebarIconTarget?
    let title: String
    var agentGlyph: String? = nil
    var agentColor: SidebarAvatarColor? = nil
    let inspect: () -> Void
    var picker: Binding<Bool>? = nil

    @Environment(SidebarPreferences.self) private var preferences
    @Environment(\.sidebarAgentIconStyle) private var agentStyle
    @Environment(\.sidebarTerminalIconStyle) private var terminalStyle
    @State private var localPicker = false
    private var showingPicker: Binding<Bool> { picker ?? $localPicker }

    private var appearance: (choice: SidebarIconChoice, source: String) {
        let standardGlyph: String
        switch kind {
        case .agent: standardGlyph = agentStyle == .copilot ? "oct-copilot" : "md-robot"
        case .terminal: standardGlyph = terminalStyle.glyph
        case .browser: standardGlyph = "fa-edge"
        }
        let standard = SidebarIconChoice(glyph: standardGlyph, color: .theme)
        let agent: SidebarIconChoice? = agentGlyph != nil || agentColor != nil
            ? .init(glyph: agentGlyph ?? standardGlyph, color: agentColor ?? .theme) : nil
        var resolved = preferences.icons.resolve(target: target, standard: standard, agent: agent)
        if case .success(let catalog) = SidebarGlyphCatalog.shared,
           let glyph = catalog.glyph(named: resolved.choice.glyph) {
            resolved.choice.glyph = glyph.name
        }
        return resolved
    }

    var body: some View {
        HStack(spacing: 2) {
            if case .success(let catalog) = SidebarGlyphCatalog.shared {
                SidebarIconPickerButton(
                    catalog: catalog, selection: appearance.choice,
                    label: target == nil
                        ? "Icon for \(title). Exact session identity unavailable; customization disabled."
                        : "Choose icon for \(title). \(appearance.source): \(appearance.choice.glyph)",
                    enabled: target != nil,
                    action: { showingPicker.wrappedValue = true }
                )
                .frame(width: 24, height: 24)
                .popover(isPresented: showingPicker, arrowEdge: .trailing) {
                    if let target {
                        VStack(spacing: 0) {
                            SidebarIconPicker(
                                catalog: catalog, selection: appearance.choice, source: appearance.source,
                                notice: preferences.iconNotice ?? (catalog.glyph(named: appearance.choice.glyph) == nil
                                    ? "This icon is unavailable in the bundled font. Choose another icon or reset." : nil),
                                choose: { preferences.setIcon($0, for: target) },
                                resetDefault: { preferences.resetIconToDefault(for: target) },
                                resetAgentSelection: kind == .agent ? { preferences.resetIconToAgentSelection(for: target) } : nil,
                                close: { showingPicker.wrappedValue = false }
                            )
                            Divider()
                            Button("Show details") {
                                showingPicker.wrappedValue = false
                                inspect()
                            }
                            .padding(10)
                        }
                    }
                }
                .onChange(of: target) { _, _ in showingPicker.wrappedValue = false }
            } else {
                Image(systemName: "questionmark.square")
                    .frame(width: 24, height: 24)
                    .help(SidebarGlyphCatalog.notice ?? "Icon font unavailable")
            }
        }
    }
}
