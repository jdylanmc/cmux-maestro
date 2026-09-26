import SwiftUI

private struct SidebarDensityKey: EnvironmentKey {
    static let defaultValue = SidebarDensity.compact
}

private struct SidebarContentWidthKey: EnvironmentKey {
    static let defaultValue: Double = 300
}

private struct SidebarPrepareSeenKey: EnvironmentKey {
    static let defaultValue: (SidebarSeenTarget) -> () -> Void = { _ in {} }
}

private struct SidebarDismissManagedKey: EnvironmentKey {
    static let defaultValue: ((SidebarDismissedManagedOutcome) -> Void)? = nil
}

private struct SidebarAgentIconStyleKey: EnvironmentKey {
    static let defaultValue = SidebarAgentIconStyle.maestro
}

private struct SidebarTerminalIconStyleKey: EnvironmentKey {
    static let defaultValue = SidebarTerminalIconStyle.ghost
}

private struct SidebarFocusedSurfaceKey: EnvironmentKey {
    static let defaultValue: SidebarSeenTarget? = nil
}

extension EnvironmentValues {
    var sidebarFocusedSurface: SidebarSeenTarget? {
        get { self[SidebarFocusedSurfaceKey.self] }
        set { self[SidebarFocusedSurfaceKey.self] = newValue }
    }
    var sidebarDismissManaged: ((SidebarDismissedManagedOutcome) -> Void)? {
        get { self[SidebarDismissManagedKey.self] }
        set { self[SidebarDismissManagedKey.self] = newValue }
    }
    var sidebarTerminalIconStyle: SidebarTerminalIconStyle {
        get { self[SidebarTerminalIconStyleKey.self] }
        set { self[SidebarTerminalIconStyleKey.self] = newValue }
    }
    var sidebarAgentIconStyle: SidebarAgentIconStyle {
        get { self[SidebarAgentIconStyleKey.self] }
        set { self[SidebarAgentIconStyleKey.self] = newValue }
    }
    var sidebarPrepareSeen: (SidebarSeenTarget) -> () -> Void {
        get { self[SidebarPrepareSeenKey.self] }
        set { self[SidebarPrepareSeenKey.self] = newValue }
    }
    var sidebarDensity: SidebarDensity {
        get { self[SidebarDensityKey.self] }
        set { self[SidebarDensityKey.self] = newValue }
    }
    var sidebarContentWidth: Double {
        get { self[SidebarContentWidthKey.self] }
        set { self[SidebarContentWidthKey.self] = newValue }
    }
}

private struct SidebarTypography: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight
    @Environment(\.sidebarDensity) private var density

    func body(content: Content) -> some View {
        let resolved: Font.TextStyle = density == .compact ? style
            : style == .caption2 ? .caption : style == .caption ? .subheadline : .body
        content.font(.system(resolved).weight(weight))
    }
}

private extension View {
    func sidebarFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(SidebarTypography(style: style, weight: weight))
    }
}

private extension SidebarTone {
    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .purple: .purple
        case .pink: .pink
        case .attention:
            Color(nsColor: NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                    return NSColor(srgbRed: 0.38, green: 0.77, blue: 0.55, alpha: 1)
                }
                return NSColor(srgbRed: 0.15, green: 0.45, blue: 0.27, alpha: 1)
            })
        case .green: .green
        case .red: .red
        case .neutral: .secondary
        }
    }
}

private extension SidebarAvatarColor {
    var tint: Color? {
        switch self {
        case .theme: nil
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .gray: .gray
        }
    }
}

struct SidebarAgentIcon: View {
    let visual: SidebarVisual
    var style: SidebarAgentIconStyle? = nil
    var avatar: String? = nil
    var color: SidebarAvatarColor? = nil
    @Environment(\.sidebarAgentIconStyle) private var environmentStyle

    private var selectedGlyph: String {
        avatar ?? ((style ?? environmentStyle) == .copilot ? "oct-copilot" : "md-robot")
    }

    var body: some View {
        SidebarGlyphIcon(name: selectedGlyph, tint: color?.tint ?? .primary)
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent · \(visual.title) · \(selectedGlyph)")
        .help("Agent · \(visual.title) · \(selectedGlyph)")
    }
}

struct SidebarTerminalIcon: View {
    var style: SidebarTerminalIconStyle? = nil
    @Environment(\.sidebarTerminalIconStyle) private var environmentStyle

    var body: some View {
        SidebarGlyphIcon(name: (style ?? environmentStyle).glyph)
        .frame(width: 24, height: 24)
        .accessibilityLabel("Terminal")
    }
}

struct SidebarActivityBackground: View {
    let visual: SidebarVisual
    var suppressAnimation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private let mint = Color(red: 0.68, green: 0.92, blue: 0.79)

    var body: some View {
        Group {
            switch SidebarPresentation.activityTreatment(visual, reduceMotion: reduceMotion || suppressAnimation) {
            case .shimmer:
                GeometryReader { geometry in
                    let width = max(48, geometry.size.width * 0.35)
                    ZStack(alignment: .leading) {
                        mint.opacity(colorScheme == .dark ? 0.035 : 0.06)
                        LinearGradient(
                            colors: [.clear, mint.opacity(colorScheme == .dark ? 0.17 : 0.26), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: width)
                        .phaseAnimator([false, true]) { content, trailing in
                            content.offset(x: trailing ? geometry.size.width : -width)
                        } animation: { trailing in
                            trailing ? .linear(duration: 2.6) : .linear(duration: 0)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            case .steadyWorking:
                RoundedRectangle(cornerRadius: 4).fill(mint.opacity(colorScheme == .dark ? 0.07 : 0.11))
            case .steadyAlert:
                RoundedRectangle(cornerRadius: 4).fill(.red.opacity(0.065))
            case .none:
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarFocusBorder: ViewModifier {
    let workspaceID: UUID
    let surfaceID: UUID
    @Environment(\.sidebarFocusedSurface) private var target
    private var focused: Bool { target == .surface(workspaceID: workspaceID, surfaceID: surfaceID) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if focused {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .shadow(color: .accentColor.opacity(0.65), radius: 3)
                        .padding(.vertical, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(focused ? .isSelected : [])
    }
}

struct SidebarStateBadge: View {
    let visual: SidebarVisual

    var body: some View {
        Image(systemName: visual.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(visual.tone.color)
            .frame(width: 18, height: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(visual.title)
            .help(visual.title)
    }
}

private struct SessionStateSummary: View {
    let session: SidebarCopilotSession

    var body: some View {
        SidebarActionLayout {
            WorkStateLabel(state: session.state)
            if session.liveness != .alive {
                SidebarStateBadge(visual: SidebarPresentation.process(session.liveness))
            }
        }
    }
}

private struct SidebarActionLayout<Content: View>: View {
    var spacing: Double = 4
    @ViewBuilder var content: Content
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing(spacing)) { content }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: density.spacing(spacing)) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CollapsedBranchSummary: View {
    let summary: SidebarBranchSummary

    var body: some View {
        let lines = SidebarPresentation.collapsed(summary)
        if !lines.isEmpty {
            HStack(spacing: 4) {
                if summary.running > 0 { Label("\(summary.running)", systemImage: SidebarPresentation.state(.working).symbol) }
                if summary.blocked > 0 { Label("\(summary.blocked)", systemImage: SidebarPresentation.state(.blocked).symbol) }
                if summary.attention > 0 { Label("\(summary.attention)", systemImage: "exclamationmark.circle") }
                if summary.omittedActive > 0 { Label("+\(summary.omittedActive)", systemImage: "exclamationmark.triangle") }
                if summary.incomplete {
                    Image(systemName: "info.circle")
                }
            }
            .sidebarFont(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Collapsed branch. \(lines.joined(separator: ". "))")
            .help(lines.joined(separator: ". "))
        }
    }
}

private struct WorkspaceAttentionLabel: View {
    let summary: SidebarWorkspaceAttention

    var body: some View {
        if let label = summary.label {
            Label(label, systemImage: "exclamationmark.circle")
                .sidebarFont(.caption)
                .foregroundStyle(SidebarTone.red.color)
                .fixedSize(horizontal: false, vertical: true)
                .help(summary.detail)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workspace-attention-summary")
        }
    }
}

struct SidebarView: View {
    // CMUX overlays 50 points of bottom chrome; the current SDK forwards no inset.
    private static let hostFooterClearance: CGFloat = 50
    let model: SidebarConnectionModel
    @Bindable private var preferences: SidebarPreferences
    @State private var showingHistory = false
    @State private var inspector: SidebarInspection?
    @State private var showingInspector = false
    @State private var hoverGroup = SidebarHoverGroup()
    @Environment(\.scenePhase) private var scenePhase

    init(model: SidebarConnectionModel, preferences: SidebarPreferences) {
        self.model = model
        self.preferences = preferences
    }

    var body: some View {
        GeometryReader { geometry in
            content(pinnedHeight: min(220, max(80, geometry.size.height * 0.36)))
                .environment(\.sidebarContentWidth, max(0, geometry.size.width - preferences.layout.density.spacing(20)))
        }
    }

    private var visibleWork: SidebarVisibleWork {
        SidebarVisibleWork(
            tree: model.copilot.tree, managed: model.orchestration.snapshot.nodes,
            history: preferences.history,
            showEnded: preferences.showEnded || preferences.historyNotice != nil || preferences.attentionNotice != nil
        )
    }

    private var attentionSummary: SidebarWorkspaceAttention {
        let work = visibleWork
        return SidebarPresentation.workspaceAttention(
            sessions: work.tree.sessions, managed: work.managed,
            availability: model.orchestration.availability, now: Date()
        )
    }

    private var focusedSurface: SidebarSeenTarget? {
        guard case .connected = model.state else { return nil }
        return SidebarPresentation.focusedSurface(in: model.hierarchy)
    }

    private var connected: Bool {
        if case .connected = model.state { return true }
        return false
    }

    private var pinnedDetails: SidebarDetailContent {
        SidebarPresentation.pinnedDetails(
            hierarchy: model.hierarchy, connected: connected, tree: model.copilot.tree,
            managed: model.orchestration.snapshot, availability: model.orchestration.availability, now: Date()
        )
    }

    private var inspectorDetails: SidebarDetailContent? {
        inspector.flatMap {
            SidebarPresentation.inspectorDetails(
                for: $0, hierarchy: model.hierarchy, connected: connected, tree: model.copilot.tree,
                managed: model.orchestration.snapshot, availability: model.orchestration.availability, now: Date()
            )
        }
    }

    private var managedSelection: Binding<UUID?> {
        Binding(get: {
            if case .managed(let node) = inspector?.target { return node.id }
            return nil
        }, set: { if let id = $0 { inspectManaged(id) } })
    }

    private var unmanagedSelection: Binding<UnmanagedSelection?> {
        Binding(get: {
            if case .unmanaged(let selection) = inspector?.target { return selection }
            return nil
        }, set: { if let selection = $0 { inspect(selection) } })
    }

    private func content(pinnedHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: preferences.layout.density.spacing(6)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workspaces").sidebarFont(.subheadline, weight: .semibold)
                Spacer()
                ManagedSourceNotice(
                    availability: model.orchestration.availability,
                    hasNodes: !model.orchestration.snapshot.nodes.isEmpty
                )
                Menu {
                    ForEach(SidebarMode.allCases) { mode in
                        Button {
                            preferences.selectedMode = mode
                        } label: {
                            if mode == preferences.selectedMode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                        .accessibilityIdentifier("sidebar-mode-\(mode.rawValue)")
                    }
                    Divider()
                    Button("Mark all nonblocking notices as read") {
                        acknowledge(model.copilot.tree.acknowledgeableOutcomes)
                    }
                    .disabled(model.copilot.tree.acknowledgeableOutcomes.isEmpty)
                    .accessibilityIdentifier("sidebar-acknowledge-all")
                    Button("Sidebar settings…") { showingHistory = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .help("View and sidebar settings")
                .accessibilityLabel("View and sidebar settings")
                .accessibilityIdentifier("sidebar-history-settings")
                .popover(isPresented: $showingHistory) { historySettings }
            }
            if attentionSummary.total > 0 {
                HStack {
                    Label(SidebarCountText.attention(attentionSummary.total), systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(SidebarTone.red.color)
                        .help(attentionSummary.detail)
                    Spacer(minLength: 0)
                }
            }
            if let notice = preferences.historyNotice {
                Text(notice)
                    .font(.caption2).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-history-notice")
            }
            if let notice = SidebarGlyphCatalog.notice {
                Text(notice).font(.caption2).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = preferences.iconNotice {
                Text(notice).font(.caption2).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-icon-notice")
            }
            if let notice = preferences.attentionNotice {
                Text(notice).font(.caption2).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-attention-notice")
            }
            if let notice = preferences.layoutNotice {
                Text(notice).font(.caption2).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-layout-notice")
            }

            ScrollView {
                // Workspace rows already contain whole subtrees. Avoid lazy root
                // placement cycling during remote accessibility scrolling.
                VStack(alignment: .leading, spacing: preferences.layout.density.spacing(6)) {
                    outlineContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("sidebar-mode-content")

            SidebarPinnedFooter(content: pinnedDetails, maximumHeight: pinnedHeight, inspect: {
                guard let target = pinnedDetails.inspection?.target else { return }
                switch target {
                case .managed(let node): inspectManaged(node.id)
                case .unmanaged(let selection): inspect(selection)
                }
            })
            .popover(isPresented: $showingInspector) {
                SidebarInspector(content: inspectorDetails) {
                    showingInspector = false
                    inspector = nil
                }
            }

            if let message = model.navigation.status.message, model.navigation.status != .selected {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sidebar-navigation-status")
            }
            if let explanation = model.navigation.permissionSummary {
                Label(explanation, systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            connectionStatus
                .accessibilityIdentifier("sidebar-connection-status")
        }
        .padding(preferences.layout.density.spacing(10))
        .padding(.bottom, Self.hostFooterClearance)
        .environment(preferences)
        .environment(\.sidebarHoverGroup, hoverGroup)
        .environment(\.sidebarAgentHoverProvider, { target in
            let connected: Bool
            if case .connected = model.state { connected = true } else { connected = false }
            return SidebarAgentHoverContent.card(
                for: target, hierarchy: model.hierarchy, connected: connected,
                tree: model.copilot.tree, managed: model.orchestration.snapshot,
                availability: model.orchestration.availability, now: Date()
            )
        })
        .environment(\.sidebarHoverConnected, {
            if case .connected = model.state { return true }
            return false
        }())
        .environment(\.sidebarDensity, preferences.layout.density)
        .environment(\.sidebarAgentIconStyle, preferences.agentIconStyle)
        .environment(\.sidebarTerminalIconStyle, preferences.terminalIconStyle)
        .environment(\.sidebarFocusedSurface, focusedSurface)
        .environment(\.sidebarPrepareSeen, prepareSeen)
        .environment(\.sidebarDismissManaged, dismissManaged)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            preferences.refreshLayout()
            preferences.refreshIcons()
            model.copilot.updateHistory(preferences.history)
            model.copilot.updateAttention(preferences.attention)
            model.setVisible(true)
        }
        .onChange(of: preferences.history) { _, history in model.copilot.updateHistory(history) }
        .onChange(of: preferences.attention) { _, attention in model.copilot.updateAttention(attention) }
        .onChange(of: model.hierarchy) { old, new in
            preferences.refreshLayout()
            if let target = SidebarPresentation.focusInteraction(from: old, to: new) {
                prepareSeen(target)()
            }
        }
        .onChange(of: model.copilot.tree) { _, _ in preferences.refreshLayout() }
        .onChange(of: inspectorDetails == nil) { _, unavailable in
            if unavailable { inspector = nil }
        }
        .onChange(of: showingInspector) { _, showing in
            if !showing { inspector = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                preferences.refreshLayout()
                preferences.refreshIcons()
            }
        }
        .onDisappear { model.setVisible(false) }
    }

    @ViewBuilder private var outlineContent: some View {
        switch preferences.selectedMode {
        case .hierarchy:
            HierarchyContent(
                model: model, layout: preferences.layout,
                visibleWork: visibleWork,
                setExpanded: { preferences.setExpanded($1, for: $0) },
                dismiss: dismiss, acknowledge: acknowledge,
                managedSelection: managedSelection,
                selection: unmanagedSelection
            )
        case .taskboard:
            if !model.orchestration.snapshot.nodes.isEmpty {
                ManagedHierarchyContent(
                    polling: model.orchestration, hierarchy: model.hierarchy,
                    navigation: model.navigation, layout: preferences.layout,
                    setExpanded: { preferences.setExpanded($1, for: $0) },
                    selectedID: managedSelection,
                    displayNodes: visibleWork.managed, copilotTree: visibleWork.tree
                )
            }
            TaskboardContent(
                tree: visibleWork.tree, hierarchy: model.hierarchy,
                navigation: model.navigation, dismiss: dismiss, acknowledge: acknowledge,
                selection: unmanagedSelection
            )
        }
    }

    private func dismiss(_ outcome: SidebarDismissedOutcome) {
        // Revalidate against the current projection, not a stale button's captured row.
        let failure = model.copilot.tree.sessions.first(where: { $0.id == outcome.sessionID })?
            .nodes.first(where: { $0.id == outcome.childID })?.dismissibleFailure(sessionID: outcome.sessionID)
        guard model.copilot.tree.dismissibleOutcomes.contains(outcome) || failure == outcome else { return }
        let captured = SidebarSeenWork.capture(
            .child(sessionID: outcome.sessionID, childID: outcome.childID),
            tree: model.copilot.tree
        )
        if !captured.notices.isEmpty {
            preferences.markSeen(captured, in: model.copilot.tree)
            guard preferences.attentionNotice == nil else { return }
            model.copilot.updateAttention(preferences.attention)
        }
        guard model.copilot.tree.dismissibleOutcomes.contains(outcome) else { return }
        preferences.dismiss([outcome])
        model.copilot.updateHistory(preferences.history)
    }

    private func dismissManaged(_ outcome: SidebarDismissedManagedOutcome) {
        guard let node = model.orchestration.snapshot.nodes.first(where: { $0.id == outcome.nodeID }),
              SidebarPresentation.dismissibleManagedFailure(node, tree: model.copilot.tree) == outcome,
              !visibleWork.managed.contains(where: { $0.parentId == node.id }) else { return }
        let captured = SidebarSeenWork.capture(
            .surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId),
            tree: model.copilot.tree
        )
        if !captured.notices.isEmpty {
            preferences.markSeen(captured, in: model.copilot.tree)
            guard preferences.attentionNotice == nil else { return }
            model.copilot.updateAttention(preferences.attention)
        }
        preferences.dismissManaged(outcome)
    }

    private func acknowledge(_ outcomes: Set<SidebarAcknowledgedOutcome>) {
        preferences.acknowledge(outcomes, in: model.copilot.tree)
        model.copilot.updateAttention(preferences.attention)
    }

    private func prepareSeen(_ target: SidebarSeenTarget) -> () -> Void {
        let captured = SidebarSeenWork.capture(
            target, tree: model.copilot.tree
        )
        return {
            preferences.markSeen(captured, in: model.copilot.tree)
            model.copilot.updateAttention(preferences.attention)
            model.copilot.updateHistory(preferences.history)
        }
    }

    private func inspectManaged(_ id: UUID) {
        guard let node = model.orchestration.snapshot.nodes.first(where: { $0.id == id }),
              openInspector(.managed(node)) else { return }
        prepareSeen(.surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId))()
    }

    private func inspect(_ selection: UnmanagedSelection) {
        guard openInspector(.unmanaged(selection)) else { return }
        switch selection {
        case .workspace: break
        case .surface(let workspaceID, let surfaceID):
            prepareSeen(.surface(workspaceID: workspaceID, surfaceID: surfaceID))()
        case .session(let id): prepareSeen(.session(id))()
        case .child(let sessionID, let childID):
            prepareSeen(.child(sessionID: sessionID, childID: childID))()
        }
    }

    private func openInspector(_ target: SidebarInspection.Target) -> Bool {
        guard let subject = SidebarPresentation.inspection(
            for: target, hierarchy: model.hierarchy, connected: connected, tree: model.copilot.tree,
            managed: model.orchestration.snapshot, availability: model.orchestration.availability
        ) else {
            inspector = nil
            showingInspector = true
            return false
        }
        inspector = subject
        showingInspector = true
        return true
    }

    private var historySettings: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sidebar settings").font(.headline)
                Spacer()
                SidebarCloseButton(label: "Close sidebar settings", id: "sidebar-close-settings") {
                    showingHistory = false
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            ScrollView { settingsContents }
        }
        .frame(width: 300)
        .frame(maxHeight: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-settings-panel")
    }

    private var settingsContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout").font(.headline)
            Picker("Agent icon", selection: $preferences.agentIconStyle) {
                ForEach(SidebarAgentIconStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sidebar-agent-icon-style")
            Picker("Terminal icon", selection: $preferences.terminalIconStyle) {
                ForEach(SidebarTerminalIconStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sidebar-terminal-icon-style")
            Text("Click or right-click an item icon to choose from the bundled font. Your choices override agent selections until reset.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset all icon preferences") { preferences.resetIcons() }
                .disabled(preferences.icons.overrides.isEmpty && preferences.iconNotice == nil)
                .help("Remove human icon choices in every window and follow agent selections again. Other preferences are unchanged.")
                .accessibilityIdentifier("sidebar-reset-icons")
            Picker("View", selection: $preferences.selectedMode) {
                ForEach(SidebarMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .accessibilityIdentifier("sidebar-mode-picker")
            Picker("Density", selection: Binding(
                get: { preferences.layout.density },
                set: { preferences.setDensity($0) }
            )) {
                ForEach(SidebarDensity.allCases) { density in Text(density.title).tag(density) }
            }
            .accessibilityLabel("Sidebar density")
            .accessibilityValue(preferences.layout.density.title)
            .accessibilityHint("Changes spacing and text size without hiding work")
            .accessibilityIdentifier("sidebar-density")
            Text("Comfortable uses larger text and spacing. Expansion is saved across reloads and moves.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Expand all branches") { preferences.expandAll() }
                .disabled(preferences.layout.collapsed.isEmpty || preferences.layoutNotice != nil)
                .help("Reveal all branches in every window. Does not change history or acknowledgements.")
            Text("Collapse keeps state and attention summaries visible. Limit: 2,048 identities / 1 MiB; oldest branches reopen when full.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = preferences.layoutNotice {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
            }
            Button("Reset layout settings") { preferences.resetLayout() }
                .help("Restore Compact density and expand every branch. History and acknowledgements are unchanged.")
                .accessibilityIdentifier("sidebar-reset-layout")
            Divider()
            Text("Completed work history").font(.headline)
            Toggle("Show ended agents", isOn: $preferences.showEnded)
                .help("Show ended observations still retained by history. Never restarts an agent or opens a terminal.")
            Text("Ended agents leave the active outline automatically. Failures stay until dismissed with ×; blockers and live descendants remain visible.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Retain for", selection: Binding(
                get: { preferences.history.retention },
                set: {
                    preferences.setRetention($0)
                    model.copilot.updateHistory(preferences.history)
                }
            )) {
                ForEach(SidebarHistoryRetention.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Text("Only ended child work is hidden. Attention, unknown ages, and context needed by children stay visible.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Clear completed (\(model.copilot.tree.dismissibleOutcomes.count))") {
                preferences.dismiss(model.copilot.tree.dismissibleOutcomes)
                model.copilot.updateHistory(preferences.history)
            }
            .disabled(model.copilot.tree.dismissibleOutcomes.isEmpty)
            .help("Dismiss retained terminal outcomes on current-window surfaces, including collapsed branches. Does not delete source events.")
            .accessibilityIdentifier("sidebar-clear-completed")
            Button("Restore dismissed history") {
                preferences.restoreDismissed()
                model.copilot.updateHistory(preferences.history)
            }
            .disabled(preferences.history.dismissed.isEmpty)
            Text("Restoring keeps retention. Choose Never for older history. Limit: 2,048 dismissals / 1 MiB.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = preferences.historyNotice {
                Text(notice).font(.caption).foregroundStyle(SidebarTone.attention.color)
            }
            Button("Reset history settings") {
                preferences.resetHistory()
                model.copilot.updateHistory(preferences.history)
            }
            Divider()
            Text("Attention").font(.headline)
            Text("Focusing a tab or opening details marks its nonblocking notices as read. Permissions and questions still require a response in the agent. Turn finished does not mean background work ended.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset acknowledgements") {
                preferences.resetAcknowledgements()
                model.copilot.updateAttention(preferences.attention)
            }
            .disabled(preferences.attention.acknowledged.isEmpty && preferences.attentionNotice == nil)
            Text("Limit: 2,048 identities / 1 MiB. Reset reveals current outstanding outcomes, not all past completions.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder private var connectionStatus: some View {
        switch model.state {
        case .waiting:
            Label("Waiting for CMUX", systemImage: "clock")
                .font(.caption2).foregroundStyle(.secondary)
        case .connected:
            EmptyView()
        case .degraded:
            Label("CMUX disconnected. Focus and live status unavailable.", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(SidebarTone.attention.color)
        }
    }
}

private struct ManagedOverview: View {
    let polling: SidebarOrchestrationPolling
    @State private var showingDetails = false

    var body: some View {
        HStack {
            let workers = polling.snapshot.nodes.filter { $0.role == "worker" }
            Text("\(workers.count) managed worker\(workers.count == 1 ? "" : "s")")
                .sidebarFont(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            SidebarDetailsButton(
                expanded: $showingDetails, label: "Managed orchestration",
                id: "details-managed-overview"
            )
        }
        if showingDetails {
            SidebarMetadataDetails(lines: [
                .init(title: "Source", value: "Explicit terminal-backed orchestration"),
                .init(title: "Projection", value: polling.snapshot.complete
                      ? "Complete" : "\(polling.snapshot.omittedCount) omitted or off-window"),
                .init(title: "Observed", value: polling.snapshot.generatedAt.formatted(
                    date: .abbreviated, time: .shortened
                ))
            ])
        }
    }
}

private struct ManagedSourceNotice: View {
    let availability: SidebarOrchestrationAvailability
    let hasNodes: Bool

    private var notice: (String, String)? {
        switch availability {
        case .waiting:
            return ("clock", "Managed orchestration evidence has not been published yet.")
        case .loading:
            return ("clock", "Checking managed orchestration evidence.")
        case .partial:
            return ("info.circle", "Managed orchestration evidence is incomplete.")
        case .stale:
            return ("circle.dashed", "Managed orchestration evidence is stale.")
        case .unavailable:
            return ("exclamationmark.circle", "Managed orchestration evidence is unavailable.")
        case .ready where !hasNodes:
            return nil
        case .ready, .hidden, .disconnected:
            return nil
        }
    }

    var body: some View {
        if let notice {
            Image(systemName: notice.0)
                .sidebarFont(.caption2)
                .foregroundStyle(.secondary)
                .help(notice.1)
                .accessibilityLabel(notice.1)
                .accessibilityIdentifier("managed-source-notice")
        }
    }
}

private struct ManagedDisplayNode: Identifiable {
    let node: SidebarOrchestrationNode
    let depth: Int
    let hasChildren: Bool
    let activeDescendants: Int
    var id: UUID { node.id }
}

struct ManagedHierarchyContent: View {
    let polling: SidebarOrchestrationPolling
    let hierarchy: HierarchySnapshot
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    @Binding var selectedID: UUID?
    var workspaceID: UUID? = nil
    var showsWorkspaceHeaders = true
    var displayNodes: [SidebarOrchestrationNode]? = nil
    var copilotTree: SidebarCopilotTree = .waiting
    private var nodes: [SidebarOrchestrationNode] { displayNodes ?? polling.snapshot.nodes }
    private func children(of id: UUID) -> [SidebarOrchestrationNode] {
        nodes.filter { $0.parentId == id }
    }

    private func rows(for roots: [SidebarOrchestrationNode]) -> [ManagedDisplayNode] {
        var result: [ManagedDisplayNode] = []
        func append(_ node: SidebarOrchestrationNode, depth: Int) {
            let children = children(of: node.id).sorted(by: sort)
            let descendants = descendantCount(of: node.id)
            result.append(.init(
                node: node, depth: min(depth, 8), hasChildren: !children.isEmpty,
                activeDescendants: descendants
            ))
            if layout.isExpanded(.managed(node.id)) {
                for child in children { append(child, depth: depth + 1) }
            }
        }
        for root in roots.sorted(by: sort) { append(root, depth: 0) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(workspaceGroups, id: \.id) { group in
                VStack(alignment: .leading, spacing: 2) {
                    if showsWorkspaceHeaders {
                        WorkspaceOutlineHeader(workspace: group.workspace, hierarchy: hierarchy, navigation: navigation)
                    }
                    ForEach(rows(for: group.roots)) { row in
                        ManagedNodeRow(
                            node: row.node, depth: row.depth,
                            hasChildren: row.hasChildren,
                            activeDescendants: row.activeDescendants,
                            expanded: layout.isExpanded(.managed(row.node.id)),
                            selected: selectedID == row.node.id,
                            evidenceDate: Date(),
                            availability: polling.availability,
                            copilotTree: copilotTree,
                            navigation: navigation,
                            toggleExpanded: {
                                setExpanded(.managed(row.node.id), !layout.isExpanded(.managed(row.node.id)))
                            },
                            select: { selectedID = row.node.id }
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("managed-orchestration")
    }

    private var workspaceGroups: [(id: UUID, workspace: HierarchyWorkspace?, roots: [SidebarOrchestrationNode])] {
        Dictionary(grouping: nodes.filter { $0.parentId == nil }, by: \.workspaceId)
            .filter { workspaceID == nil || $0.key == workspaceID }
            .map { id, roots in
                (id, hierarchy.workspaces.first(where: { $0.id == id }), roots)
            }
            .sorted { workspaceTitle($0.workspace) < workspaceTitle($1.workspace) }
    }

    private func workspaceTitle(_ workspace: HierarchyWorkspace?) -> String {
        guard let workspace, case .available(let title) = workspace.title, !title.isEmpty else {
            return "Workspace"
        }
        return title
    }

    private func descendantCount(of id: UUID) -> Int {
        children(of: id).reduce(0) {
            $0 + ($1.isActive ? 1 : 0) + descendantCount(of: $1.id)
        }
    }

    private func sort(_ lhs: SidebarOrchestrationNode, _ rhs: SidebarOrchestrationNode) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        return lhs.createdAt < rhs.createdAt
    }
}

private struct ManagedNodeRow: View {
    let node: SidebarOrchestrationNode
    let depth: Int
    let hasChildren: Bool
    let activeDescendants: Int
    let expanded: Bool
    let selected: Bool
    let evidenceDate: Date
    let availability: SidebarOrchestrationAvailability
    let copilotTree: SidebarCopilotTree
    let navigation: SidebarNavigation
    let toggleExpanded: () -> Void
    let select: () -> Void
    @Environment(\.sidebarDismissManaged) private var dismissManaged

    var body: some View {
        HStack(spacing: 4) {
            if hasChildren {
                ExpandButton(expanded: expanded, label: node.label, toggle: toggleExpanded)
            } else {
                Color.clear.frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
            }
            SidebarItemIcon(
                kind: .agent, target: SidebarPresentation.managedIconTarget(node, tree: copilotTree, now: evidenceDate),
                title: node.label, agentGlyph: node.iconId, agentColor: node.iconColor,
                inspect: select
            )
            FocusButton(
                target: .surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId),
                navigation: navigation, label: "Focus \(node.label)"
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(node.label).sidebarFont(.caption, weight: .medium).lineLimit(1)
                        Spacer(minLength: 0)
                        if let changes = node.currentGitChanges(at: evidenceDate) {
                            GitChangeBadge(changes: changes)
                        }
                        if activeDescendants > 0 && !expanded {
                            Label("\(activeDescendants)", systemImage: SidebarPresentation.state(.working).symbol)
                                .sidebarFont(.caption2).foregroundStyle(.secondary)
                                .help("\(activeDescendants) active descendant\(activeDescendants == 1 ? "" : "s")")
                        }
                    }
                    HStack(spacing: 4) {
                        Text(stateCaption).lineLimit(1).layoutPriority(1)
                        if let worktree = verifiedWorktree {
                            Label(
                                node.hasFreshGitEvidence(at: evidenceDate) ? worktree : "Last verified · \(worktree)",
                                systemImage: "arrow.triangle.branch"
                            )
                                .lineLimit(1).truncationMode(.middle)
                                .accessibilityLabel("Worktree \(worktree)")
                        }
                    }
                    .sidebarFont(.caption2)
                    .foregroundStyle(.secondary)
                    .help(metadataHelp)
                    if node.gitChangesStatus == "unavailable" {
                        Text("Git counts unavailable").sidebarFont(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .agentHoverPreview(.managed(node.id, generation: node.generation))
            if !hasChildren, let dismissManaged,
               let outcome = SidebarPresentation.dismissibleManagedFailure(node, tree: copilotTree) {
                Button { dismissManaged(outcome) } label: {
                    Image(systemName: "xmark").font(.caption2)
                        .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                .buttonStyle(.plain)
                .help("Dismiss this failed result from the sidebar. Does not close its terminal or stop anything.")
                .accessibilityLabel("Dismiss failed result for \(node.label)")
                .accessibilityIdentifier("dismiss-managed-\(node.id)-\(node.generation)")
            }
        }
        .background { SidebarActivityBackground(visual: stateVisual) }
        .modifier(SidebarFocusBorder(workspaceID: node.workspaceId, surfaceID: node.surfaceId))
        .padding(.leading, CGFloat(depth * 12))
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
            }
        }
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle().fill(.quaternary).frame(width: 1)
                    .padding(.leading, CGFloat(depth * 12 - 6))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("managed-node-\(node.id)")
    }

    private var metadataLine: String? {
        guard node.gitEvidenceStatus == "verified", node.gitEvidenceAt != nil else { return nil }
        switch (node.branchLabel, node.worktreeLabel) {
        case let (branch?, worktree?) where branch != worktree:
            return "\(branch)  ·  \(SidebarPathDisplay.text(worktree))"
        case let (branch?, _): return branch
        case let (_, worktree?): return SidebarPathDisplay.text(worktree)
        default: return nil
        }
    }

    private var verifiedWorktree: String? {
        guard node.gitEvidenceStatus == "verified", node.gitEvidenceAt != nil else { return nil }
        return node.worktreeLabel.map(SidebarPathDisplay.text)
    }

    private var stateCaption: String {
        if node.role == "worker", node.executionMode != .interactive {
            return "Legacy worker · \(stateVisual.title)"
        }
        if stateVisual.title.hasPrefix("State unverified") { return "State unverified" }
        if stateVisual.title.hasPrefix("Registered") { return "Registered" }
        return stateVisual.title
    }

    private var stateVisual: SidebarVisual {
        SidebarPresentation.managedState(node, availability: availability, now: evidenceDate, tree: copilotTree)
    }

    private var metadataHelp: String {
        guard let metadataLine else { return stateVisual.title }
        let location = node.hasFreshGitEvidence(at: evidenceDate)
            ? metadataLine : "Last verified location, not current Git state: \(metadataLine)"
        return "\(stateVisual.title). \(location)"
    }
}

struct GitChangeBadge: View {
    let changes: SidebarGitChanges

    var body: some View {
        HStack(spacing: 4) {
            Text("\(changes.files) \(changes.files == 1 ? "file" : "files")")
                .foregroundStyle(.secondary)
            Text("+\(changes.insertions)").foregroundStyle(SidebarTone.attention.color)
            Text("−\(changes.deletions)").foregroundStyle(.red)
        }
        .sidebarFont(.caption2)
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(changes.description)
        .help(changes.description)
    }
}

private struct WorkspaceOutlineHeader: View {
        let workspace: HierarchyWorkspace?
        let hierarchy: HierarchySnapshot
        let navigation: SidebarNavigation
        @Environment(\.sidebarHoverConnected) private var connected

        var body: some View {
            if let workspace {
                SidebarHoverRegion(data: SidebarHoverContent.workspace(workspace.id, hierarchy: hierarchy, connected: connected)) {
                    FocusButton(target: .workspace(workspace.id), navigation: navigation, label: "Focus workspace \(title)") {
                        HStack(spacing: 5) {
                            Text(title)
                                .sidebarFont(.caption2, weight: .semibold)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("managed-workspace-\(workspace.id)")
                }
            } else {
                Text("Workspace")
                    .sidebarFont(.caption2, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }

        private var title: String {
            if let workspace, case .available(let title) = workspace.title, !title.isEmpty {
                return title
            }
            return "Workspace"
        }
    }

private struct CopilotOverview: View {
    let tree: SidebarCopilotTree
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(SidebarPresentation.overview(tree)).sidebarFont(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SidebarDetailsButton(expanded: $showingDetails, label: "Copilot overview", id: "details-overview")
            }
            ForEach(SidebarPresentation.primaryWarnings(tree), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .sidebarFont(.caption).foregroundStyle(SidebarTone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SidebarTone.attention.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            if showingDetails {
                SidebarMetadataDetails(lines: [
                    .init(title: "Observation", value: tree.summary),
                    .init(title: "Warnings", value: SidebarPresentation.overviewWarnings(tree).joined(separator: "\n")),
                    .init(title: "Source issues", value: tree.issues.isEmpty ? "None reported" : tree.issues.map(\.rawValue).joined(separator: ", ")),
                    .init(title: "Counts", value: tree.hasCompleteCounts ? "Complete current observation" : "Known counts only"),
                    .init(title: "Retained outcomes", value: "\(tree.retainedHistoryCount)"),
                    .init(title: "Hidden history", value: "\(tree.hiddenHistoryCount)"),
                    .init(title: "Omitted tasks", value: "\(tree.omittedChildrenCount)"),
                    .init(title: "Observed", value: tree.generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Observation time unknown")
                ])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-copilot-status")
    }
}

private struct HierarchyContent: View {
    let model: SidebarConnectionModel
    let layout: SidebarLayoutSettings
    let visibleWork: SidebarVisibleWork
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var managedSelection: UUID?
    @Binding var selection: UnmanagedSelection?

    var body: some View {
        if !model.hierarchy.receivedSnapshot {
            SidebarNotice(title: "Waiting for hierarchy", detail: "Waiting for the first CMUX workspace snapshot.")
        } else if !model.hierarchy.workspaceListAvailable {
            SidebarNotice(title: "Workspace list unavailable", detail: "Grant workspace metadata access in CMUX extension settings.")
        } else if model.hierarchy.workspaces.isEmpty {
            SidebarNotice(title: "No shared workspaces", detail: "This CMUX window has no shared workspaces.")
        } else {
            ForEach(model.hierarchy.workspaces) { workspace in
                WorkspaceRow(
                    workspace: workspace,
                    sessions: visibleWork.tree.sessions.filter { $0.workspaceID == workspace.id },
                    countsComplete: model.copilot.tree.hasCompleteCounts,
                    navigation: model.navigation, layout: layout, setExpanded: setExpanded,
                    orchestration: model.orchestration, hierarchy: model.hierarchy,
                    displayManaged: visibleWork.managed, hiddenSurfaces: visibleWork.hiddenSurfaces,
                    copilotTree: visibleWork.tree,
                    managedSelection: $managedSelection,
                    dismiss: dismiss, acknowledge: acknowledge, selection: $selection
                )
            }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: HierarchyWorkspace
    let sessions: [SidebarCopilotSession]
    let countsComplete: Bool
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let orchestration: SidebarOrchestrationPolling
    let hierarchy: HierarchySnapshot
    let displayManaged: [SidebarOrchestrationNode]
    let hiddenSurfaces: Set<UUID>
    let copilotTree: SidebarCopilotTree
    @Binding var managedSelection: UUID?
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density
    @Environment(\.sidebarHoverConnected) private var connected
    private var expanded: Bool { layout.isExpanded(.workspace(workspace.id)) }
    private var managedNodes: [SidebarOrchestrationNode] {
        displayManaged.filter { $0.workspaceId == workspace.id }
    }
    private var unmanagedSessions: [SidebarCopilotSession] {
        let surfaces = Set(managedNodes.map(\.surfaceId))
        return sessions.filter { !surfaces.contains($0.surfaceID) }
    }
    private var attentionSummary: SidebarWorkspaceAttention {
        SidebarPresentation.workspaceAttention(
            sessions: sessions, managed: managedNodes,
            availability: orchestration.availability, now: Date()
        )
    }

    private var title: String {
        if case .available(let title) = workspace.title {
            return title.isEmpty ? "Untitled workspace" : title
        }
        return "Workspace"
    }

    private var accessibilityStatus: String {
        var labels: [String] = []
        if case .available(true) = workspace.isSelected { labels.append("Selected") }
        if case .available(true) = workspace.isPinned { labels.append("Pinned") }
        if case .available(let count) = workspace.unreadCount, count > 0 { labels.append("\(count) unread") }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(4)) {
            HStack(spacing: 5) {
                ExpandButton(expanded: expanded, label: title) {
                    setExpanded(.workspace(workspace.id), !expanded)
                }
                SidebarHoverRegion(data: SidebarHoverContent.workspace(workspace.id, hierarchy: hierarchy, connected: connected)) {
                    FocusButton(target: .workspace(workspace.id), navigation: navigation, label: "Focus workspace \(title)") {
                        HStack(spacing: 5) {
                            Text(title).sidebarFont(.caption2, weight: .semibold)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            if case .available(true) = workspace.isPinned {
                                StatusBadge(symbol: "pin.fill", label: "Pinned")
                            }
                            if case .available(let count) = workspace.unreadCount, count > 0 {
                                UnreadBadge(count: count)
                            }
                        }
                    }
                    .accessibilityValue(accessibilityStatus)
                }
                Menu {
                    FocusButton(
                        target: .workspace(workspace.id), navigation: navigation,
                        label: "Focus workspace \(title)"
                    ) { Text("Focus workspace") }
                    Button(expanded ? "Collapse workspace" : "Expand workspace") {
                        setExpanded(.workspace(workspace.id), !expanded)
                    }
                    .accessibilityIdentifier("workspace-menu-expansion-\(workspace.id)")
                    Divider()
                    Button("Workspace details") {
                        selection = .workspace(workspace.id)
                    }
                    .accessibilityIdentifier("workspace-menu-details-\(workspace.id)")
                } label: {
                    Image(systemName: "ellipsis").font(.caption2).foregroundStyle(.secondary)
                        .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .help("Workspace actions")
                .accessibilityLabel("Actions for workspace \(title)")
                .accessibilityIdentifier("workspace-menu-\(workspace.id)")
            }
            WorkspaceAttentionLabel(summary: attentionSummary)
                .padding(.leading, SidebarPresentation.minimumControlSize + 5)
            if expanded {
                if !managedNodes.isEmpty {
                    ManagedHierarchyContent(
                        polling: orchestration, hierarchy: hierarchy,
                        navigation: navigation, layout: layout, setExpanded: setExpanded,
                        selectedID: $managedSelection, workspaceID: workspace.id,
                        showsWorkspaceHeaders: false, displayNodes: displayManaged, copilotTree: copilotTree
                    )
                }
                switch workspace.surfaces {
                case .unavailable:
                    Text("Surface metadata unavailable").font(.caption2).foregroundStyle(.secondary)
                case .available(let surfaces) where surfaces.isEmpty:
                    Text("No shared surfaces").font(.caption2).foregroundStyle(.secondary)
                case .available(let surfaces):
                    ForEach(SidebarPresentation.unmanagedSurfaces(
                        surfaces.filter { !hiddenSurfaces.contains($0.id) },
                        workspaceID: workspace.id, managed: managedNodes
                    )) { surface in
                        SurfaceRow(
                            workspaceID: workspace.id, surface: surface,
                            sessions: unmanagedSessions.filter { $0.surfaceID == surface.id },
                            countsComplete: countsComplete,
                            navigation: navigation, layout: layout, setExpanded: setExpanded,
                            dismiss: dismiss, acknowledge: acknowledge, selection: $selection
                        )
                    }
                }
            }
        }
        .padding(.vertical, density.spacing(2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-\(workspace.id.uuidString)")
    }
}

private struct SurfaceRow: View {
    let workspaceID: UUID
    let surface: HierarchySurface
    let sessions: [SidebarCopilotSession]
    let countsComplete: Bool
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density
    private var singleSession: SidebarCopilotSession? { sessions.count == 1 ? sessions.first : nil }
    private var expanded: Bool {
        layout.isExpanded(.surface(surface.id))
            && (singleSession.map { layout.isExpanded(.session($0.id)) } ?? true)
    }
    private var hasChildren: Bool {
        singleSession.map { !$0.outlineNodes.isEmpty } ?? !sessions.isEmpty
    }

    private var title: String { surface.title.isEmpty ? "Untitled surface" : surface.title }
    private var inspectionLabel: String {
        if let singleSession {
            return "\(title), \(SidebarPresentation.sessionState(singleSession).title). Show session details"
        }
        return "\(title). Show \(surface.kind.title.lowercased()) details"
    }
    private var accessibilityStatus: String {
        var labels: [String] = []
        if let singleSession { labels.append(SidebarPresentation.sessionState(singleSession).title) }
        if surface.isFocused { labels.append("Focused") }
        if surface.isPinned { labels.append("Pinned") }
        if surface.unreadCount > 0 { labels.append("\(surface.unreadCount) unread") }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(4)) {
            HStack(spacing: 4) {
                if hasChildren {
                    ExpandButton(expanded: expanded, label: title) {
                        setExpanded(.surface(surface.id), !expanded)
                        if let singleSession { setExpanded(.session(singleSession.id), !expanded) }
                    }
                } else {
                    Color.clear.frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                if let singleSession {
                    SidebarItemIcon(
                        kind: .agent, target: .session(singleSession.id), title: title,
                        agentGlyph: singleSession.iconId,
                        agentColor: singleSession.iconColor.flatMap(SidebarAvatarColor.init(rawValue:)),
                        inspect: inspect
                    )
                } else if surface.kind == .agentSession {
                    SidebarItemIcon(kind: .agent, target: nil, title: title, inspect: inspect)
                } else if surface.kind == .terminal {
                    SidebarItemIcon(kind: .terminal, target: .surface(surface.id), title: title, inspect: inspect)
                } else if surface.kind == .browser {
                    SidebarItemIcon(kind: .browser, target: .surface(surface.id), title: title, inspect: inspect)
                } else {
                    Button(action: inspect) {
                        Image(systemName: surface.kind.symbolName)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(inspectionLabel)
                    .accessibilityLabel(inspectionLabel)
                }
                FocusButton(
                    target: .surface(workspaceID: workspaceID, surfaceID: surface.id),
                    navigation: navigation, label: "Focus \(surface.kind.title) \(title)"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).sidebarFont(.caption, weight: .medium).lineLimit(1)
                        Text(rowMetadata).sidebarFont(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(rowMetadataHelp)
                        if let singleSession {
                            ActivityCaption(text: SidebarPresentation.activityCaption(
                                singleSession.activity,
                                runningShells: singleSession.foldedShellCount(parentID: nil)
                            ))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityValue(accessibilityStatus)
                .agentHoverPreview(singleSession.map { .session($0.id) })
                if let singleSession {
                    SessionEvidenceBadge(session: singleSession)
                }
                if !expanded && hasChildren {
                    CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: sessions, complete: countsComplete))
                }
                if surface.isPinned { StatusBadge(symbol: "pin.fill", label: "Pinned") }
                if surface.unreadCount > 0 { UnreadBadge(count: surface.unreadCount) }
            }
            .background {
                if let singleSession {
                    SidebarActivityBackground(visual: SidebarPresentation.sessionState(singleSession))
                }
            }
            .modifier(SidebarFocusBorder(workspaceID: workspaceID, surfaceID: surface.id))
            if let singleSession {
                CopilotSessionContents(
                    session: singleSession, expanded: expanded,
                    navigation: navigation, layout: layout, setExpanded: setExpanded,
                    dismiss: dismiss, acknowledge: acknowledge, selection: $selection
                )
            } else if expanded {
                ForEach(sessions) { session in
                    CopilotSessionRow(
                        session: session, navigation: navigation, layout: layout, setExpanded: setExpanded,
                        dismiss: dismiss, acknowledge: acknowledge, selection: $selection
                    )
                }
            }
        }
        .padding(.vertical, density.spacing(2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surface-\(surface.id.uuidString)")
    }

    private var directoryLabel: String? {
        guard case .available(let path) = surface.workingDirectory,
              let path, !path.isEmpty else { return nil }
        return SidebarPathDisplay.text(path)
    }

    private func inspect() {
        if let singleSession { selection = .session(singleSession.id) }
        else { selection = .surface(workspaceID: workspaceID, surfaceID: surface.id) }
    }

    private var rowMetadata: String {
        var parts = [
            singleSession == nil ? surface.kind.title : "Agent",
            singleSession.map { SidebarPresentation.sessionState($0).title }
        ].compactMap { $0 }
        if let directoryLabel { parts.append(directoryLabel) }
        return parts.joined(separator: " · ")
    }

    private var rowMetadataHelp: String {
        guard directoryLabel != nil else { return rowMetadata }
        return "\(rowMetadata). Working directory; Git branch not verified by this source."
    }
}

private struct CopilotSessionRow: View {
    let session: SidebarCopilotSession
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density
    private var expanded: Bool { layout.isExpanded(.session(session.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(4)) {
            HStack(spacing: 4) {
                if !session.outlineNodes.isEmpty {
                    ExpandButton(expanded: expanded, label: "Agent children") {
                        setExpanded(.session(session.id), !expanded)
                    }
                } else {
                    Color.clear.frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                SidebarItemIcon(
                    kind: .agent, target: .session(session.id), title: "Copilot \(session.shortID)",
                    agentGlyph: session.iconId, agentColor: session.iconColor.flatMap(SidebarAvatarColor.init(rawValue:)),
                    inspect: { selection = .session(session.id) }
                )
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SidebarPresentation.sessionState(session).title)
                            .sidebarFont(.caption, weight: .medium).lineLimit(1)
                        ActivityCaption(text: SidebarPresentation.activityCaption(
                            session.activity, runningShells: session.foldedShellCount(parentID: nil)
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityValue(session.state.rawValue)
                .agentHoverPreview(.session(session.id))
                SessionEvidenceBadge(session: session)
                if !expanded && !session.outlineNodes.isEmpty {
                    CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: [session]))
                }
            }
            .background { SidebarActivityBackground(visual: SidebarPresentation.sessionState(session)) }
            CopilotSessionContents(
                session: session, expanded: expanded,
                navigation: navigation, layout: layout, setExpanded: setExpanded,
                dismiss: dismiss, acknowledge: acknowledge, selection: $selection
            )
        }
        .padding(.leading, density.spacing(12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copilot-session-\(session.id)")
        .help("Copilot session \(session.id.uuidString)")
    }
}

private struct SessionEvidenceBadge: View {
    let session: SidebarCopilotSession

    var body: some View {
        if !session.childrenComplete || session.treeDegraded {
            Image(systemName: "info.circle")
                .sidebarFont(.caption2).foregroundStyle(.secondary)
                .help("Child history incomplete; missing work is not assumed finished")
                .accessibilityLabel("Child history incomplete")
                .accessibilityIdentifier("session-evidence-\(session.id)")
        }
    }
}

private struct CopilotSessionContents: View {
    let session: SidebarCopilotSession
    let expanded: Bool
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density
    @Environment(\.sidebarContentWidth) private var contentWidth

    var body: some View {
        if !SidebarPresentation.attention(
            session.attention, state: session.state, degraded: session.attentionDegraded
        ).isEmpty {
            SidebarActionLayout {
                AttentionSummary(attention: session.attention, state: session.state, degraded: session.attentionDegraded)
            }
            .padding(.leading, 28)
        }
        if session.omittedActiveChildrenCount > 0 {
            Text("\(session.omittedActiveChildrenCount) working/blocked tasks could not fit.")
                .sidebarFont(.caption).foregroundStyle(SidebarTone.attention.color)
        }
        if expanded {
            ForEach(session.outlineChildRows(layout: layout)) { row in
                CopilotWorkRow(
                    node: row.node, session: session, navigation: navigation,
                    dismiss: dismiss, acknowledge: acknowledge,
                    expansion: row, setExpanded: setExpanded, selection: $selection
                )
                .padding(.leading, density.spacing(12) + density.indentation(
                    depth: row.node.depth, unresolved: row.node.ancestryUnresolved, width: contentWidth
                ))
            }
        }
    }
}

private struct CopilotWorkRow: View {
    let node: SidebarCopilotNode
    let session: SidebarCopilotSession
    let navigation: SidebarNavigation
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    var expansion: SidebarChildRow? = nil
    var setExpanded: ((SidebarExpansionID, Bool) -> Void)? = nil
    var paths: HierarchyPathContext? = nil
    var taskboard = false
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density
    private var hasOutcomeActions: Bool {
        node.dismissibleOutcome(sessionID: session.id) != nil
            || node.dismissibleFailure(sessionID: session.id) != nil
    }

    init(
        node: SidebarCopilotNode, session: SidebarCopilotSession,
        navigation: SidebarNavigation,
        dismiss: @escaping (SidebarDismissedOutcome) -> Void,
        acknowledge: @escaping (Set<SidebarAcknowledgedOutcome>) -> Void,
        expansion: SidebarChildRow? = nil,
        setExpanded: ((SidebarExpansionID, Bool) -> Void)? = nil,
        paths: HierarchyPathContext? = nil,
        taskboard: Bool = false,
        selection: Binding<UnmanagedSelection?> = .constant(nil)
    ) {
        self.node = node
        self.session = session
        self.navigation = navigation
        self.dismiss = dismiss
        self.acknowledge = acknowledge
        self.expansion = expansion
        self.setExpanded = setExpanded
        self.paths = paths
        self.taskboard = taskboard
        self._selection = selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(3)) {
            HStack(alignment: .top, spacing: 4) {
                if let expansion, node.hasChildren, let setExpanded {
                    ExpandButton(expanded: expansion.expanded, label: node.name) {
                        setExpanded(expansion.expansionID, !expansion.expanded)
                    }
                } else {
                    Color.clear.frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                Button {
                    selection = .child(sessionID: session.id, childID: node.id)
                } label: {
                    if node.kind == .subagent {
                        SidebarAgentIcon(
                            visual: SidebarPresentation.state(node.state)
                        )
                    } else {
                        Image(systemName: node.kind == .shell ? "terminal"
                              : node.kind == .skill ? "sparkles" : "questionmark.square")
                            .foregroundStyle(SidebarPresentation.state(node.state).tone.color)
                            .frame(width: 24, height: 24)
                    }
                }
                .buttonStyle(.plain)
                .help("\(SidebarPresentation.state(node.state).title). Show details")
                .accessibilityLabel("\(node.name), \(SidebarPresentation.state(node.state).title). Show details")
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus \(node.name), \(node.state.rawValue), Copilot \(session.shortID)"
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(node.name).sidebarFont(.caption, weight: .medium).lineLimit(2)
                        Text("\(SidebarPresentation.kind(node.kind)) · \(SidebarPresentation.state(node.state).title)")
                            .sidebarFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        ActivityCaption(text: SidebarPresentation.activityCaption(
                            node.activity, runningShells: taskboard ? 0 : session.foldedShellCount(parentID: node.id)
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .agentHoverPreview(node.kind == .subagent ? .child(sessionID: session.id, childID: node.id) : nil)
                if let summary = expansion?.collapsedSummary { CollapsedBranchSummary(summary: summary) }
                if node.ancestryUnresolved {
                    Image(systemName: "questionmark.circle")
                        .sidebarFont(.caption2).foregroundStyle(SidebarTone.attention.color)
                        .help("Unresolved ancestry")
                        .accessibilityLabel("Unresolved ancestry")
                }
                if hasOutcomeActions {
                    DismissOutcomeButton(node: node, sessionID: session.id, dismiss: dismiss)
                }
            }
            if !SidebarPresentation.attention(
                node.attention, state: node.state, degraded: node.attentionDegraded
            ).isEmpty {
                AttentionSummary(attention: node.attention, state: node.state, degraded: node.attentionDegraded)
            }
        }

        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, density.spacing(3))
        .background { SidebarActivityBackground(visual: SidebarPresentation.state(node.state)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(taskboard ? "taskboard" : "copilot")-child-\(session.id)-\(node.id)")
    }
}

struct SidebarInspector: View {
    let content: SidebarDetailContent?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(content?.title ?? "Details no longer available")
                    .sidebarFont(.subheadline, weight: .semibold).lineLimit(2)
                Spacer(minLength: 0)
                SidebarCloseButton(label: "Close details", id: "sidebar-close-details", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let content {
                        if let visual = content.visual {
                            Text(visual.title).sidebarFont(.caption).foregroundStyle(.secondary)
                        }
                        if let notice = content.notice {
                            Text(notice).sidebarFont(.caption).foregroundStyle(.secondary)
                        }
                        SidebarMetadataDetails(lines: content.lines.filter { $0.copyableSessionID == nil })
                        ForEach(content.lines.filter { $0.copyableSessionID != nil }) { line in
                            SidebarSessionDetail(line: line)
                        }
                        if !content.otherActivity.isEmpty {
                            DisclosureGroup("Other activity (\(content.otherActivity.count))") {
                                ForEach(content.otherActivity) { node in
                                    HStack {
                                        Text(node.name).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(SidebarPresentation.state(node.state).title).foregroundStyle(.secondary)
                                    }.sidebarFont(.caption2)
                                }
                            }.sidebarFont(.caption)
                        }
                    } else {
                        Text("The subject changed or access is unavailable. Open Details again from a current row.")
                            .sidebarFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 420)
        }
        .padding(12)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-inspector")
    }
}

private struct DismissOutcomeButton: View {
    let node: SidebarCopilotNode
    let sessionID: UUID
    let dismiss: (SidebarDismissedOutcome) -> Void

    var body: some View {
        if let outcome = node.dismissibleOutcome(sessionID: sessionID) ?? node.dismissibleFailure(sessionID: sessionID) {
            Button { dismiss(outcome) } label: {
                Image(systemName: "xmark").font(.caption)
                    .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
            }
            .buttonStyle(.borderless)
            .help("Dismiss this \(node.state.rawValue) outcome from history; does not stop or delete work")
            .accessibilityLabel("Dismiss \(node.name), \(node.state.rawValue) outcome")
            .accessibilityIdentifier("dismiss-outcome-\(sessionID)-\(node.id)")
        }
    }
}

private struct TaskboardContent: View {
    let tree: SidebarCopilotTree
    let hierarchy: HierarchySnapshot
    let navigation: SidebarNavigation
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density

    private let groups: [(String, [CopilotWorkState])] = [
        ("Blocked", [.blocked]), ("Working", [.working]), ("Idle", [.idle]),
        ("Done / ended", [.completed, .failed, .cancelled]), ("Unknown", [.unknown]),
    ]

    var body: some View {
        ForEach(tree.sessions) { session in
            let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
            TaskboardSessionRow(
                session: session, title: SidebarPresentation.surfaceTitle(for: session, in: hierarchy),
                paths: paths, navigation: navigation, acknowledge: acknowledge, selection: $selection
            )
        }
        if tree.sessions.allSatisfy({ $0.nodes.isEmpty }) {
            SidebarNotice(
                title: SidebarPresentation.emptyChildHistoryTitle(complete: tree.hasCompleteCounts),
                detail: "History may hide ended work; this does not mean the session is finished. Workspace focus remains in Hierarchy."
            )
        } else {
            ForEach(groups, id: \.0) { title, states in
                let sessions = tree.sessions.filter { session in session.nodes.contains { states.contains($0.state) } }
                if !sessions.isEmpty {
                    if let state = states.first {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SidebarPresentation.state(state).tone.color)
                    }
                    ForEach(sessions) { session in
                        let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
                        Text(SidebarPresentation.surfaceTitle(for: session, in: hierarchy))
                            .sidebarFont(.caption).foregroundStyle(.secondary)
                        ForEach(session.nodes.filter { states.contains($0.state) }) { node in
                            CopilotWorkRow(
                                node: node, session: session, navigation: navigation, dismiss: dismiss,
                                acknowledge: acknowledge, paths: paths, taskboard: true, selection: $selection
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct TaskboardSessionRow: View {
    let session: SidebarCopilotSession
    let title: String
    let paths: HierarchyPathContext
    let navigation: SidebarNavigation
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SidebarItemIcon(
                    kind: .agent, target: .session(session.id), title: title,
                    agentGlyph: session.iconId, agentColor: session.iconColor.flatMap(SidebarAvatarColor.init(rawValue:)),
                    inspect: { selection = .session(session.id) }
                )
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    Text(title).sidebarFont(.caption, weight: .semibold).lineLimit(1)
                }
                .agentHoverPreview(.session(session.id))
                Spacer(minLength: 0)
                Button { selection = .session(session.id) } label: {
                    Image(systemName: "info.circle")
                        .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                .buttonStyle(.borderless)
                .help("Details for \(title)")
                .accessibilityLabel("Details for \(title)")
                .accessibilityIdentifier("details-session-\(session.id)")
            }
            SidebarActionLayout {
                SessionStateSummary(session: session)
            }
            AttentionSummary(attention: session.attention, state: session.state, degraded: session.attentionDegraded)
            ActivityCaption(text: SidebarPresentation.activityCaption(session.activity))
            if !session.childrenComplete || session.treeDegraded {
                Label("Children unavailable", systemImage: "info.circle")
                    .sidebarFont(.caption2).foregroundStyle(.secondary)
                    .help("Child history incomplete; missing work is not assumed finished")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("taskboard-session-attention-\(session.id)")
        .background { SidebarActivityBackground(visual: SidebarPresentation.sessionState(session)) }
        .modifier(SidebarFocusBorder(workspaceID: session.workspaceID, surfaceID: session.surfaceID))
    }
}

private struct AttentionSummary: View {
    let attention: [AgentAttention]
    let state: CopilotWorkState
    let degraded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarPresentation.attention(attention, state: state, degraded: degraded), id: \.self) { text in
                Label(text, systemImage: state == .blocked ? "pause.circle" : "exclamationmark.circle")
                    .sidebarFont(.caption)
                    .foregroundStyle(state == .blocked || state == .failed
                                     || attention.contains(where: { $0.kind.isBlocking || $0.kind == .error })
                                     ? SidebarTone.red.color : SidebarTone.attention.color)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ActivityCaption: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text).sidebarFont(.caption2).foregroundStyle(.secondary).lineLimit(1).help(text)
        }
    }
}

private struct SidebarCloseButton: View {
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.caption2)
                .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

struct SidebarDetailsButton: View {
    @Binding var expanded: Bool
    let label: String
    let id: String
    var accessibilityTitle: String { "Details for \(label)" }

    func toggle() { expanded.toggle() }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: expanded ? "info.circle.fill" : "info.circle")
                .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
        }
        .buttonStyle(.borderless)
        .help("\(expanded ? "Hide" : "Show") details for \(label)")
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows metadata without focusing, dismissing, or acknowledging work")
        .accessibilityIdentifier(id)
    }
}

struct SidebarMetadataDetails: View {
    let lines: [SidebarDetailLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.title).foregroundStyle(.secondary)
                    Text(line.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .sidebarFont(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.vertical, 5)
        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
        .accessibilityIdentifier("sidebar-row-details")
    }
}

private struct SidebarSessionDetail: View {
    let line: SidebarDetailLine
    var showsTitle = true
    var copySessionID: (UUID) -> Bool = { SidebarSessionCopy.copy($0) }

    var body: some View {
        if let sessionID = line.copyableSessionID {
            VStack(alignment: .leading, spacing: 1) {
                if showsTitle { Text(line.title).sidebarFont(.caption2).foregroundStyle(.secondary) }
                SidebarCopyableValue(value: line.value, label: line.title) {
                    copySessionID(sessionID)
                }
            }
        }
    }
}

struct SidebarPinnedFooter: View {
    let content: SidebarDetailContent
    var maximumHeight: CGFloat = 220
    let inspect: () -> Void
    var copySessionID: (UUID) -> Bool = { SidebarSessionCopy.copy($0) }
    @State private var contentHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("Active window").sidebarFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if content.inspection != nil {
                    Button("Details", action: inspect)
                        .buttonStyle(.borderless)
                        .sidebarFont(.caption)
                        .frame(minHeight: SidebarPresentation.minimumControlSize)
                        .accessibilityLabel("Details for active window")
                        .accessibilityIdentifier("sidebar-pinned-inspect")
                }
            }
            .frame(minHeight: 24)
            ScrollView {
                footerContents
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, max(0, maximumHeight - 33)))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-pinned-details")
    }

    private var footerContents: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                if content.isAgent { SidebarPlaceholderPet() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).sidebarFont(.caption, weight: .semibold).lineLimit(2)
                    if let visual = content.visual {
                        Label(visual.title, systemImage: visual.symbol)
                            .sidebarFont(.caption2).foregroundStyle(visual.tone.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let model = content.lines.first(where: { $0.title == "Model" }) {
                        Text(model.value).sidebarFont(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).help(model.value)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(content.lines.filter { $0.copyableSessionID != nil }) { line in
                SidebarSessionDetail(line: line, showsTitle: false, copySessionID: copySessionID)
            }
            if let notice = content.notice {
                Text(notice).sidebarFont(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let changes = content.gitChanges { GitChangeBadge(changes: changes) }
            ForEach(content.lines.filter {
                ["Branch", "Worktree", "Git evidence", "Git changes", "Working directory"].contains($0.title)
                    && ($0.title != "Git changes" || content.gitChanges == nil)
            }) { line in
                Text(line.title == "Working directory" ? line.value : "\(line.title): \(line.value)")
                    .sidebarFont(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("\(line.title): \(line.value)")
                    .accessibilityLabel("\(line.title): \(line.value)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarPlaceholderPet: View {
    var body: some View {
        Canvas { context, size in
            // Original two-eared pebble silhouette; no provider asset or runtime pet.
            var body = Path()
            body.move(to: CGPoint(x: 5, y: 25))
            body.addQuadCurve(to: CGPoint(x: 7, y: 12), control: CGPoint(x: 2, y: 17))
            body.addLine(to: CGPoint(x: 6, y: 3))
            body.addQuadCurve(to: CGPoint(x: 15, y: 9), control: CGPoint(x: 14, y: 3))
            body.addQuadCurve(to: CGPoint(x: 23, y: 8), control: CGPoint(x: 19, y: 6))
            body.addQuadCurve(to: CGPoint(x: 31, y: 2), control: CGPoint(x: 25, y: 2))
            body.addLine(to: CGPoint(x: 30, y: 13))
            body.addQuadCurve(to: CGPoint(x: 31, y: 27), control: CGPoint(x: 36, y: 22))
            body.addQuadCurve(to: CGPoint(x: 27, y: 32), control: CGPoint(x: 31, y: 33))
            body.addLine(to: CGPoint(x: 23, y: 29))
            body.addQuadCurve(to: CGPoint(x: 14, y: 30), control: CGPoint(x: 18, y: 32))
            body.addLine(to: CGPoint(x: 9, y: 33))
            body.closeSubpath()
            context.fill(body, with: .color(.secondary.opacity(0.5)))
            for x: CGFloat in [13, 24] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: size.height * 0.5, width: 2, height: 3)),
                             with: .color(.primary))
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityLabel("Original placeholder pet; no live pet integration")
        .help("Original placeholder pet; no live pet integration")
    }
}

private struct PathDetail: View {
    let label: String
    let path: String?

    private var displayText: String {
        HierarchyAvailability<String?>.available(path).pathDisplayText
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "folder")
                .foregroundStyle(.tertiary)
            Text(displayText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(displayText)
        }
        .sidebarFont(.caption2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(displayText)")
    }
}

struct FocusButton<Content: View>: View {
    let target: SidebarNavigationTarget
    let navigation: SidebarNavigation
    let label: String
    @ViewBuilder var content: Content
    @Environment(\.sidebarPrepareSeen) private var prepareSeen
    func focus() {
        switch target {
        case .workspace:
            navigation.select(target)
        case .surface(let workspaceID, let surfaceID):
            let onSuccess = prepareSeen(.surface(workspaceID: workspaceID, surfaceID: surfaceID))
            navigation.select(target, onSuccess: onSuccess)
        }
    }

    var body: some View {
        Button(action: focus) {
            content.frame(minHeight: SidebarPresentation.minimumControlSize).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .disabled(navigation.disabledReason(for: target) != nil)
            .help(navigation.disabledReason(for: target) ?? label)
            .accessibilityLabel(label)
            .accessibilityHint(navigation.disabledReason(for: target) ?? "Selects this surface or workspace in CMUX")
    }
}

private struct ExpandButton: View {
    let expanded: Bool
    let label: String
    let toggle: () -> Void
    @Environment(\.sidebarDensity) private var density
    var body: some View {
        Button(action: toggle) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .sidebarFont(.caption2)
                .frame(width: max(SidebarPresentation.minimumControlSize, density.controlSize),
                       height: max(SidebarPresentation.minimumControlSize, density.controlSize))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(label)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded
            ? "Hides branch details, keeping running, blocked and attention summaries. Does not dismiss or acknowledge work."
            : "Shows branch details. Does not focus, dismiss or acknowledge work.")
        .help("\(expanded ? "Collapse" : "Expand") \(label); saved across reloads")
    }
}

private struct WorkStateLabel: View {
    let state: CopilotWorkState
    var body: some View {
        let visual = SidebarPresentation.state(state)
        Text(visual.title)
            .sidebarFont(.caption)
            .foregroundStyle(visual.tone.color)
    }
}

private struct StatusBadge: View {
    let symbol: String
    let label: String
    var body: some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(label)
            .help(label)
    }
}

private struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .accessibilityLabel("\(count) unread")
    }
}

private struct SidebarNotice: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
