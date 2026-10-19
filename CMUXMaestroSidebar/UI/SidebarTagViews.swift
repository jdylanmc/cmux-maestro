import SwiftUI

extension SidebarTagColor {
    var swiftUI: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }
}

/// One tag. Opaque background, so the chosen foreground's contrast is the rendered contrast.
/// A dashed outline marks a tag only the agent assigned.
struct SidebarTagChip: View {
    let tag: SidebarResolvedTag
    var compact = true

    var body: some View {
        HStack(spacing: 3) {
            Text(tag.slug).lineLimit(1)
            if !compact { Text("· \(tag.owners)").fontWeight(.regular) }
        }
        .font(.system(size: compact ? 9 : 10, weight: .semibold))
        .foregroundStyle(tag.foreground.swiftUI)
        .padding(.horizontal, 5)
        .padding(.vertical, compact ? 1 : 2)
        .background(Capsule().fill(tag.background.swiftUI))
        .overlay {
            if !tag.human {
                Capsule().strokeBorder(tag.foreground.swiftUI.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .fixedSize()
        .help("\(tag.slug) · \(tag.owners)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tag \(tag.slug), \(tag.owners)")
        .accessibilityIdentifier("sidebar-tag-\(tag.slug)")
    }
}

/// Compact chips inline with an agent title. Shows as many whole chips as fit and counts the rest.
struct SidebarTagStrip: View {
    let tags: [SidebarResolvedTag]

    var body: some View {
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array((0...tags.count).reversed()), id: \.self) { shown in
                    HStack(spacing: 3) {
                        ForEach(tags.prefix(shown)) { SidebarTagChip(tag: $0) }
                        if shown < tags.count {
                            Text("+\(tags.count - shown)")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }
            }
            .help(SidebarResolvedTag.summary(tags))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags: \(SidebarResolvedTag.summary(tags))")
            .accessibilityIdentifier("sidebar-tag-strip")
        }
    }
}

/// An agent title with its compact tags right-aligned. The title keeps priority for space.
struct SidebarTaggedTitle<Title: View>: View {
    let tags: [SidebarResolvedTag]
    @ViewBuilder var title: Title

    var body: some View {
        HStack(spacing: 4) {
            title.layoutPriority(1)
            if !tags.isEmpty {
                Spacer(minLength: 4)
                SidebarTagStrip(tags: tags)
            }
        }
    }
}

/// Wrapping row of chips for details.
struct SidebarTagFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return (origins, widest, y + line)
    }
}

/// Every tag with its owners, for pinned details and the details popover.
struct SidebarTagList: View {
    let tags: [SidebarResolvedTag]
    var edit: (() -> Void)? = nil

    var body: some View {
        if !tags.isEmpty || edit != nil {
            SidebarTagFlow {
                ForEach(tags) { SidebarTagChip(tag: $0, compact: false) }
                if let edit {
                    Button("Edit tags…", action: edit)
                        .buttonStyle(.link).font(.caption2)
                        .accessibilityIdentifier("sidebar-edit-tags")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar-tag-list")
        }
    }
}

/// Human tag editing for one exact session. The agent's own tags show with their owner and
/// stay unchanged; colors apply to the slug everywhere.
struct SidebarTagEditor: View {
    let session: UUID
    let preferences: SidebarPreferences
    let close: () -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var coloring: String?

    private var tags: [SidebarResolvedTag] { preferences.tags(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags").font(.headline)
                Spacer(minLength: 0)
                SidebarCloseButton(label: "Close tags", id: "sidebar-close-tags", action: close)
            }
            TextField("Your tags", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .accessibilityIdentifier("sidebar-tag-input")
            ForEach([error, preferences.tagNotice].compactMap { $0 }, id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(SidebarTone.red.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-tag-error")
            }
            if !tags.isEmpty {
                SidebarTagFlow {
                    ForEach(tags) { tag in
                        Button { coloring = coloring == tag.slug ? nil : tag.slug } label: {
                            SidebarTagChip(tag: tag, compact: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color for \(tag.slug), \(tag.owners)")
                        .accessibilityValue(coloring == tag.slug ? "Selected" : "")
                    }
                }
            }
            if let coloring, let tag = tags.first(where: { $0.slug == coloring }) {
                swatches(for: tag)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sidebar-tag-save")
            }
        }
        .padding(14)
        .frame(width: 280)
        .accessibilityIdentifier("sidebar-tag-editor")
        .onAppear {
            preferences.refreshTags()
            text = preferences.humanTags(for: session).joined(separator: ", ")
        }
    }

    private func swatches(for tag: SidebarResolvedTag) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 7), spacing: 6) {
                ForEach(SidebarTagSwatch.allCases, id: \.self) { swatch in
                    Button { error = preferences.setTagColor(swatch, for: tag.slug) } label: {
                        Circle().fill(swatch.color.swiftUI).frame(width: 18, height: 18)
                            .overlay { if tag.swatch == swatch { Circle().strokeBorder(Color.primary, lineWidth: 2) } }
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(swatch.title)
                    .accessibilityLabel(swatch.title)
                    .accessibilityAddTraits(tag.swatch == swatch ? .isSelected : [])
                }
            }
            Button("Use automatic color") { error = preferences.setTagColor(nil, for: tag.slug) }
                .disabled(tag.swatch == nil)
                .font(.caption)
                .accessibilityIdentifier("sidebar-tag-automatic-color")
        }
    }

    private func save() {
        if let message = preferences.setHumanTags(text, for: session) {
            error = message
        } else {
            close()
        }
    }
}

private struct SidebarTagEditorPopover: ViewModifier {
    @Binding var session: UUID?
    @Environment(SidebarPreferences.self) private var preferences: SidebarPreferences?

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }),
                        arrowEdge: .trailing) {
            if let id = session, let preferences {
                SidebarTagEditor(session: id, preferences: preferences, close: { session = nil })
            }
        }
    }
}

extension View {
    /// Presents the tag editor for the exact session in `session`; nil closes it.
    func sidebarTagEditor(_ session: Binding<UUID?>) -> some View {
        modifier(SidebarTagEditorPopover(session: session))
    }
}

extension SidebarPresentation {
    /// A focus label that also names each tag and its owners, for VoiceOver and tooltips.
    static func taggedLabel(_ label: String, tags: [SidebarResolvedTag]) -> String {
        tags.isEmpty ? label : "\(label). Tags: \(SidebarResolvedTag.summary(tags))"
    }

    /// The exact session whose tags a hover card shows. Children have none of their own.
    static func tagSession(
        for target: SidebarAgentHoverTarget, managed: SidebarOrchestrationSnapshot, tree: SidebarCopilotTree, now: Date
    ) -> UUID? {
        switch target {
        case .session(let id): return id
        case .child: return nil
        case .managed(let id, let generation):
            let matches = managed.nodes.filter { $0.id == id && $0.generation == generation }
            guard matches.count == 1, case .session(let session)? = managedIconTarget(matches[0], tree: tree, now: now)
            else { return nil }
            return session
        }
    }
}

extension SidebarDetailContent {
    /// The exact agent session these details describe; nil for surfaces, workspaces and children.
    var tagSessionID: UUID? {
        guard isAgent else { return nil }
        if let petSessionID { return petSessionID }
        if case .managed = inspection?.target { return inspection?.sessionID }
        return nil
    }
}
