import SwiftUI

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
        }
    }
}

/// A controlled picker: the owner supplies the current choice and handles every mutation.
struct SidebarIconPicker: View {
    let catalog: SidebarGlyphCatalog
    let selection: SidebarIconChoice
    let source: String
    var notice: String? = nil
    let choose: (SidebarIconChoice) -> Void
    let resetDefault: () -> Void
    var resetAgentSelection: (() -> Void)? = nil
    let close: () -> Void

    @State private var query = ""
    @FocusState private var focus: Field?
    private enum Field: Hashable { case search, glyph(String) }
    private static let columns = 7
    private var results: [SidebarGlyphCatalog.Glyph] { catalog.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                glyph(selection.glyph)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose icon").font(.headline)
                    Text(source).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("icon-picker-source")
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            Text(selection.glyph).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
                .accessibilityIdentifier("icon-picker-selection")
            TextField("Search icons", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
                .accessibilityLabel("Search bundled font icons")
                .accessibilityIdentifier("icon-picker-search")
                .onKeyPress(.downArrow) {
                    guard let first = results.first else { return .ignored }
                    focus = .glyph(first.name)
                    return .handled
                }
            Text("\(results.count) icons").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("icon-picker-count")
            ScrollViewReader { proxy in
                ScrollView {
                    if results.isEmpty {
                        Text("No matching icons. Try another name.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: Self.columns), spacing: 4) {
                            ForEach(results) { entry in
                                Button { selectGlyph(entry.name) } label: {
                                    glyph(entry.name)
                                        .frame(width: 32, height: 32)
                                        .background(selection.glyph == entry.name ? Color.accentColor.opacity(0.12) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 5))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 5)
                                                .strokeBorder(selection.glyph == entry.name ? Color.accentColor : .clear, lineWidth: 2)
                                        }
                                }
                                .buttonStyle(.plain)
                                .focused($focus, equals: .glyph(entry.name))
                                .accessibilityLabel(entry.name)
                                .accessibilityValue(selection.glyph == entry.name ? "Selected" : "")
                                .accessibilityIdentifier("icon-picker-glyph-\(entry.name)")
                                .help(entry.name)
                                .id(entry.name)
                            }
                        }
                        .padding(2)
                        .onMoveCommand { direction in moveFocus(direction) }
                    }
                }
                .frame(height: 216)
                .onChange(of: focus) { _, field in
                    if case .glyph(let name) = field { proxy.scrollTo(name) }
                }
                .onChange(of: query) { _, _ in
                    if let first = results.first { proxy.scrollTo(first.name, anchor: .top) }
                }
            }
            HStack(spacing: 4) {
                ForEach(SidebarAvatarColor.allCases) { color in
                    Button { selectColor(color) } label: {
                        Circle().fill(Color(nsColor: color.nativeColor))
                            .frame(width: 18, height: 18)
                            .overlay {
                                if color == selection.color {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(color == .theme ? Color(nsColor: .textBackgroundColor) : .white)
                                }
                            }
                            .frame(width: 26, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.title)
                    .accessibilityValue(color == selection.color ? "Selected" : "")
                    .accessibilityIdentifier("icon-picker-color-\(color.rawValue)")
                    .help(color.title)
                }
            }
            Divider()
            Button("Reset to default", action: resetDefault)
                .accessibilityIdentifier("icon-picker-reset-default")
            if let resetAgentSelection {
                Button("Reset to agent selection", action: resetAgentSelection)
                    .accessibilityIdentifier("icon-picker-reset-agent")
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("icon-picker-notice")
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { focus = .search }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icon-picker")
    }

    func selectGlyph(_ name: String) {
        guard let entry = catalog.glyph(named: name) else { return }
        choose(.init(glyph: entry.name, color: selection.color))
    }

    func selectColor(_ color: SidebarAvatarColor) {
        choose(.init(glyph: selection.glyph, color: color))
    }

    private func glyph(_ name: String) -> some View {
        SidebarGlyphIcon(name: name, tint: Color(nsColor: selection.color.nativeColor), catalog: .success(catalog))
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard case .glyph(let name) = focus,
              let index = results.firstIndex(where: { $0.name == name }) else { return }
        let delta: Int
        switch direction {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -Self.columns
        case .down: delta = Self.columns
        @unknown default: return
        }
        let next = index + delta
        if results.indices.contains(next) { focus = .glyph(results[next].name) }
        else if next < 0 { focus = .search }
    }
}

/// Native secondary-click handling opens the same anchored popover, not a row menu.
final class SidebarIconNativeButton: NSButton {
    var activate: () -> Void = {}

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self
        action = #selector(openPicker)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openPicker() { activate() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    override func rightMouseDown(with event: NSEvent) { if isEnabled { activate() } }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if isEnabled { activate() }
        } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 121 && event.modifierFlags.contains(.shift) {
            if isEnabled { activate() }
        } else { super.keyDown(with: event) }
    }
}

struct SidebarIconPickerButton: NSViewRepresentable {
    let catalog: SidebarGlyphCatalog
    let selection: SidebarIconChoice
    let label: String
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> SidebarIconNativeButton { SidebarIconNativeButton() }

    func updateNSView(_ button: SidebarIconNativeButton, context: Context) {
        button.activate = action
        button.isEnabled = enabled
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("icon-picker-button")
        button.contentTintColor = selection.color.nativeColor
        if let outline = catalog.path(for: selection.glyph) {
            let bounds = outline.boundingBoxOfPath
            let scale = min(20 / bounds.width, 20 / bounds.height)
            button.image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.translateBy(x: 10 - bounds.midX * scale, y: 10 - bounds.midY * scale)
                context.scaleBy(x: scale, y: scale)
                context.addPath(outline)
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
                return true
            }
            button.image?.isTemplate = true
        } else {
            button.image = NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: "Icon unavailable")
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarIconNativeButton, context: Context) -> CGSize? {
        CGSize(width: 24, height: 24)
    }
}
