import SwiftUI

private struct SidebarDensityKey: EnvironmentKey {
    static let defaultValue = SidebarDensity.compact
}

private struct SidebarContentWidthKey: EnvironmentKey {
    static let defaultValue: Double = 300
}

private extension EnvironmentValues {
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

private struct SidebarActionLayout<Content: View>: View {
    var spacing: Double = 4
    @ViewBuilder var content: Content
    @Environment(\.sidebarDensity) private var density
    @Environment(\.sidebarContentWidth) private var width

    var body: some View {
        let layout = density.stacksActions(width: width)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: density.spacing(spacing)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: density.spacing(spacing)))
        layout { content }
    }
}

private struct CollapsedBranchSummary: View {
    let summary: SidebarBranchSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Collapsed details").foregroundStyle(.secondary)
            ForEach(summary.lines, id: \.self) { line in Text(line) }
        }
        .sidebarFont(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Collapsed branch. \(summary.lines.joined(separator: ". "))")
    }
}

struct SidebarView: View {
    // CMUX overlays 50 points of bottom chrome; the current SDK forwards no inset.
    private static let hostFooterClearance: CGFloat = 50
    let model: SidebarConnectionModel
    @Bindable private var preferences: SidebarPreferences
    @State private var showingHistory = false
    @Environment(\.scenePhase) private var scenePhase

    init(model: SidebarConnectionModel, preferences: SidebarPreferences) {
        self.model = model
        self.preferences = preferences
    }

    var body: some View {
        GeometryReader { geometry in
            content.environment(\.sidebarContentWidth, max(0, geometry.size.width - preferences.layout.density.spacing(48)))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: preferences.layout.density.spacing(10)) {
            HStack {
                Text("Maestro").font(.headline)
                Spacer()
                Button { showingHistory.toggle() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Sidebar layout, completed work history and attention settings")
                .accessibilityLabel("Sidebar settings")
                .accessibilityIdentifier("sidebar-history-settings")
                .popover(isPresented: $showingHistory) { historySettings }
            }
            Picker("Sidebar view", selection: $preferences.selectedMode) {
                ForEach(SidebarMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Sidebar view")

            CopilotOverview(tree: model.copilot.tree)
            if model.copilot.tree.attentionOwnerCount > 0 {
                HStack {
                    Label(SidebarCountText.attention(model.copilot.tree.attentionOwnerCount), systemImage: "bell.badge")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Acknowledge all") { acknowledge(model.copilot.tree.acknowledgeableOutcomes) }
                        .buttonStyle(.borderless).font(.caption2)
                        .disabled(model.copilot.tree.acknowledgeableOutcomes.isEmpty)
                        .help("Acknowledge nonblocking outcomes on current-window surfaces. Never answers or approves a request.")
                        .accessibilityIdentifier("sidebar-acknowledge-all")
                }
            }
            if let notice = preferences.historyNotice {
                Text(notice)
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-history-notice")
            }
            if let notice = preferences.attentionNotice {
                Text(notice).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-attention-notice")
            }
            if let notice = preferences.layoutNotice {
                Text(notice).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sidebar-layout-notice")
            }

            ScrollView {
                // Workspace rows already contain whole subtrees. Avoid lazy root
                // placement cycling during remote accessibility scrolling.
                VStack(alignment: .leading, spacing: preferences.layout.density.spacing(9)) {
                    switch preferences.selectedMode {
                    case .hierarchy:
                        HierarchyContent(
                            model: model, layout: preferences.layout,
                            setExpanded: { preferences.setExpanded($1, for: $0) },
                            dismiss: dismiss, acknowledge: acknowledge
                        )
                    case .taskboard:
                        TaskboardContent(
                            tree: model.copilot.tree, hierarchy: model.hierarchy,
                            navigation: model.navigation, dismiss: dismiss, acknowledge: acknowledge
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("sidebar-mode-content")

            if let message = model.navigation.status.message {
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
        .environment(\.sidebarDensity, preferences.layout.density)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            preferences.refreshLayout()
            model.copilot.updateHistory(preferences.history)
            model.copilot.updateAttention(preferences.attention)
            model.setVisible(true)
        }
        .onChange(of: preferences.history) { _, history in model.copilot.updateHistory(history) }
        .onChange(of: preferences.attention) { _, attention in model.copilot.updateAttention(attention) }
        .onChange(of: model.hierarchy) { _, _ in preferences.refreshLayout() }
        .onChange(of: model.copilot.tree) { _, _ in preferences.refreshLayout() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { preferences.refreshLayout() }
        }
        .onDisappear { model.setVisible(false) }
    }

    private func dismiss(_ outcome: SidebarDismissedOutcome) {
        // Revalidate against the current projection, not a stale button's captured row.
        guard model.copilot.tree.dismissibleOutcomes.contains(outcome) else { return }
        preferences.dismiss([outcome])
        model.copilot.updateHistory(preferences.history)
    }

    private func acknowledge(_ outcomes: Set<SidebarAcknowledgedOutcome>) {
        preferences.acknowledge(outcomes, in: model.copilot.tree)
        model.copilot.updateAttention(preferences.attention)
    }

    private var historySettings: some View {
        ScrollView { settingsContents }
            .frame(maxHeight: 600)
    }

    private var settingsContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout").font(.headline)
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
            Text("Compact keeps the original spacing. Comfortable adds room and larger detail text. Expansion is saved by identity across reloads and moves.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Expand all branches") { preferences.expandAll() }
                .disabled(preferences.layout.collapsed.isEmpty || preferences.layoutNotice != nil)
                .help("Reveal all branches in every window. Does not change history or acknowledgements.")
            Text("Collapse hides details, not running, blocked or attention summaries. Up to 2,048 collapsed identities are saved; the oldest reopen when storage fills.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = preferences.layoutNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            Button("Reset layout settings") { preferences.resetLayout() }
                .help("Restore Compact density and expand every branch. History and acknowledgements are unchanged.")
                .accessibilityIdentifier("sidebar-reset-layout")
            Divider()
            Text("Completed work history").font(.headline)
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
            Text("Only finished, failed, or cancelled child history is hidden. Outstanding attention and unknown completion ages stay visible. Parent context is kept for remaining children.")
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
            Text("Retention still applies after restoring. Choose Never to see older history. Dismissals are stored locally, up to 2,048 outcomes.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = preferences.historyNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            Button("Reset history settings") {
                preferences.resetHistory()
                model.copilot.updateHistory(preferences.history)
            }
            Divider()
            Text("Attention").font(.headline)
            Text("Acknowledgement is local to Maestro. Pending permissions and questions cannot be acknowledged. Turn finished means the main turn ended; background work may still run.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset acknowledgements") {
                preferences.resetAcknowledgements()
                model.copilot.updateAttention(preferences.attention)
            }
            .disabled(preferences.attention.acknowledged.isEmpty && preferences.attentionNotice == nil)
            Text("Stores up to 2,048 outcome identities. Reset reveals current outstanding outcomes, not all historical completions.")
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
        case .connected(let workspaces, let surfaces):
            Text("CMUX · \(workspaces) workspaces · \(surfaces) surfaces")
                .font(.caption2).foregroundStyle(.secondary)
        case .degraded:
            Label("CMUX disconnected. Focus and live status unavailable.", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}

private struct CopilotOverview: View {
    let tree: SidebarCopilotTree

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !tree.sessions.isEmpty {
                Text(SidebarCountText.copilotSessions(tree.sessions.count))
                    .font(.subheadline.weight(.semibold))
                if tree.hasCompleteCounts {
                    Text(SidebarCountText.runningChildren(tree.knownRunningChildren))
                        .font(.caption)
                } else if tree.knownRunningChildren > 0 {
                    Text("At least \(SidebarCountText.runningChildren(tree.knownRunningChildren, known: true))")
                        .font(.caption)
                } else {
                    Text("Running child count unavailable")
                        .font(.caption)
                }
                Text("\(tree.retainedHistoryCount) retained outcomes · \(tree.hiddenHistoryCount) hidden by history controls")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(tree.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tree.omittedChildrenCount > 0 {
                Text("\(tree.omittedChildrenCount) child tasks omitted by display limits. Working/blocked work and its ancestry are prioritized.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if tree.omittedActiveChildrenCount > 0 {
                Text("\(tree.omittedActiveChildrenCount) additional working/blocked tasks exceed the display limit.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let date = tree.generatedAt {
                HStack(spacing: 3) {
                    Text(tree.availability == .partial ? "Partial observation" : "Observed")
                    Text(date, style: .relative)
                    Text("ago")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar-copilot-status")
    }
}

private struct HierarchyContent: View {
    let model: SidebarConnectionModel
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void

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
                    sessions: model.copilot.tree.sessions.filter { $0.workspaceID == workspace.id },
                    countsComplete: model.copilot.tree.hasCompleteCounts,
                    navigation: model.navigation, layout: layout, setExpanded: setExpanded,
                    dismiss: dismiss, acknowledge: acknowledge
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
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Environment(\.sidebarDensity) private var density
    private var expanded: Bool { layout.isExpanded(.workspace(workspace.id)) }

    private var title: String {
        if case .available(let title) = workspace.title {
            return title.isEmpty ? "Untitled workspace" : title
        }
        return "Workspace metadata unavailable"
    }

    private var accessibilityStatus: String {
        var labels: [String] = []
        if case .available(true) = workspace.isSelected { labels.append("Selected") }
        if case .available(true) = workspace.isPinned { labels.append("Pinned") }
        if case .available(let count) = workspace.unreadCount, count > 0 { labels.append("\(count) unread") }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(7)) {
            HStack(spacing: 5) {
                ExpandButton(expanded: expanded, label: title) {
                    setExpanded(.workspace(workspace.id), !expanded)
                }
                FocusButton(target: .workspace(workspace.id), navigation: navigation, label: "Focus workspace \(title)") {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                        Text(title).sidebarFont(.subheadline, weight: .semibold).lineLimit(2)
                        Spacer(minLength: 0)
                        if case .available(true) = workspace.isSelected {
                            StatusBadge(symbol: "checkmark.circle.fill", label: "Selected")
                        }
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
            AvailabilityPathRows(
                rootPath: workspace.rootPath,
                projectRootPath: workspace.projectRootPath
            )
            if !expanded {
                CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: sessions, complete: countsComplete))
            }
            if expanded {
                switch workspace.surfaces {
                case .unavailable:
                    Text("Surface metadata unavailable").font(.caption2).foregroundStyle(.secondary)
                case .available(let surfaces) where surfaces.isEmpty:
                    Text("No shared surfaces").font(.caption2).foregroundStyle(.secondary)
                case .available(let surfaces):
                    ForEach(surfaces) { surface in
                        SurfaceRow(
                            workspaceID: workspace.id, surface: surface,
                            sessions: sessions.filter { $0.surfaceID == surface.id },
                            countsComplete: countsComplete,
                            navigation: navigation, layout: layout, setExpanded: setExpanded,
                            dismiss: dismiss, acknowledge: acknowledge
                        )
                    }
                }
            }
        }
        .padding(density.spacing(8))
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
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
    @Environment(\.sidebarDensity) private var density
    private var expanded: Bool { layout.isExpanded(.surface(surface.id)) }

    private var title: String { surface.title.isEmpty ? "Untitled surface" : surface.title }
    private var accessibilityStatus: String {
        var labels: [String] = []
        if surface.isFocused { labels.append("Focused") }
        if surface.isPinned { labels.append("Pinned") }
        if surface.unreadCount > 0 { labels.append("\(surface.unreadCount) unread") }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(6)) {
            HStack(spacing: 5) {
                if !sessions.isEmpty {
                    ExpandButton(expanded: expanded, label: title) {
                        setExpanded(.surface(surface.id), !expanded)
                    }
                }
                FocusButton(
                    target: .surface(workspaceID: workspaceID, surfaceID: surface.id),
                    navigation: navigation, label: "Focus \(surface.kind.title) \(title)"
                ) {
                    HStack(spacing: 5) {
                        Image(systemName: surface.kind.symbolName)
                        Text(title).sidebarFont(.caption, weight: .medium).lineLimit(2)
                        Spacer(minLength: 0)
                        if surface.isFocused { StatusBadge(symbol: "scope", label: "Focused") }
                        if surface.isPinned { StatusBadge(symbol: "pin.fill", label: "Pinned") }
                        if surface.unreadCount > 0 { UnreadBadge(count: surface.unreadCount) }
                    }
                }
                .accessibilityValue(accessibilityStatus)
            }
            SurfacePathDetail(workingDirectory: surface.workingDirectory)
            if !expanded {
                CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: sessions, complete: countsComplete))
            }
            if expanded {
                ForEach(sessions) { session in
                    CopilotSessionRow(
                        session: session, navigation: navigation, layout: layout, setExpanded: setExpanded,
                        dismiss: dismiss, acknowledge: acknowledge
                    )
                }
            }
        }
        .padding(density.spacing(6))
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surface-\(surface.id.uuidString)")
    }
}

private struct CopilotSessionRow: View {
    let session: SidebarCopilotSession
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Environment(\.sidebarDensity) private var density
    @Environment(\.sidebarContentWidth) private var contentWidth
    private var expanded: Bool { layout.isExpanded(.session(session.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(5)) {
            HStack(alignment: .top, spacing: 4) {
                ExpandButton(expanded: expanded, label: "Copilot \(session.shortID)") {
                    setExpanded(.session(session.id), !expanded)
                }
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Copilot · \(session.shortID)").sidebarFont(.caption, weight: .semibold)
                        WorkStateLabel(state: session.state)
                        Text(session.model ?? "Model unknown").sidebarFont(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityValue("\(session.state.rawValue), \(session.model ?? "model unknown"), process \(session.liveness.rawValue)")
            }
            Text("Process: \(session.liveness.rawValue)")
                .sidebarFont(.caption2).foregroundStyle(.secondary)
            SidebarActionLayout(spacing: 8) {
                AttentionSummary(attention: session.attention, state: session.state, degraded: session.attentionDegraded)
                AcknowledgeOutcomeButton(
                    attention: session.attention, sessionID: session.id, ownerID: nil,
                    degraded: session.attentionDegraded, acknowledge: acknowledge
                )
            }
            ActivityDetail(activity: session.activity)
            if session.attentionOwnerCount > 0 {
                Text(SidebarCountText.attentionRows(session.attentionOwnerCount))
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text("\(session.retainedHistoryCount) retained outcomes · \(session.hiddenHistoryCount) hidden")
                .font(.caption2).foregroundStyle(.secondary)
            if session.knownRunningChildren > 0 {
                Label(SidebarCountText.runningChildren(session.knownRunningChildren, known: true), systemImage: "arrow.trianglehead.2.clockwise")
                    .font(.caption2).foregroundStyle(.blue)
            }
            if session.omittedChildrenCount > 0 {
                Text("\(session.omittedChildrenCount) child tasks omitted; working/blocked tasks and ancestry shown first.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if session.omittedActiveChildrenCount > 0 {
                Text("\(session.omittedActiveChildrenCount) working/blocked tasks could not fit.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !expanded {
                CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: [session]))
            }
            if expanded {
                if session.nodes.isEmpty {
                    Text(session.childrenComplete ? "No visible child tasks; history controls may hide ended work." : "Child history unavailable or loading")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(session.childRows(layout: layout)) { row in
                    let node = row.node
                    if node.ancestryUnresolved && node.parentID == nil {
                        Label("Unresolved ancestry", systemImage: "questionmark.folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: density.spacing(4)) {
                        SidebarActionLayout(spacing: 8) {
                            HStack(alignment: .top, spacing: 4) {
                                if node.hasChildren {
                                    ExpandButton(expanded: row.expanded, label: node.name) {
                                        setExpanded(row.expansionID, !row.expanded)
                                    }
                                }
                                FocusButton(
                                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                                    navigation: navigation, label: "Focus \(node.name), \(node.state.rawValue), Copilot \(session.shortID)"
                                ) {
                                    CopilotChildLabel(node: node)
                                }
                            }
                            DismissOutcomeButton(node: node, sessionID: session.id, dismiss: dismiss)
                            AcknowledgeOutcomeButton(
                                attention: node.attention, sessionID: session.id, ownerID: node.id,
                                degraded: node.attentionDegraded, acknowledge: acknowledge
                            )
                        }
                        if let summary = row.collapsedSummary { CollapsedBranchSummary(summary: summary) }
                    }
                    .padding(.leading, density.indentation(depth: node.depth, unresolved: node.ancestryUnresolved, width: contentWidth))
                    .accessibilityIdentifier("copilot-child-\(session.id)-\(node.id)")
                }
                if !session.childrenComplete {
                    Text(session.treeDegraded ? "Child tree incomplete; no completion is inferred for missing items." : "Partial child history; missing tasks are not assumed finished.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, density.spacing(4))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copilot-session-\(session.id)")
        .help("Copilot session \(session.id.uuidString)")
    }
}

private struct CopilotChildLabel: View {
    let node: SidebarCopilotNode
    @Environment(\.sidebarDensity) private var density
    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(2)) {
            Label(node.name, systemImage: node.kind.symbolName)
                .sidebarFont(.caption).lineLimit(2)
            WorkStateLabel(state: node.state)
            AttentionSummary(attention: node.attention, state: node.state, degraded: node.attentionDegraded)
            ActivityDetail(activity: node.activity)
            if node.historyAncestor {
                Text("Kept for child context").sidebarFont(.caption2).foregroundStyle(.secondary)
            } else if node.state.isTerminal {
                if let timestamp = node.terminalTimestamp {
                    HStack(spacing: 3) {
                        Text("Ended")
                        Text(timestamp, style: .relative)
                        Text("ago")
                    }
                    .sidebarFont(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Completion age unknown").sidebarFont(.caption2).foregroundStyle(.secondary)
                }
            }
            if let model = node.model {
                Text(model).sidebarFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct DismissOutcomeButton: View {
    let node: SidebarCopilotNode
    let sessionID: UUID
    let dismiss: (SidebarDismissedOutcome) -> Void

    var body: some View {
        if let outcome = node.dismissibleOutcome(sessionID: sessionID) {
            Button { dismiss(outcome) } label: {
                Image(systemName: "xmark").font(.caption2).frame(width: 22, height: 22)
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
    @Environment(\.sidebarDensity) private var density

    private let groups: [(String, [CopilotWorkState])] = [
        ("Blocked", [.blocked]), ("Working", [.working]), ("Idle", [.idle]),
        ("Done / ended", [.completed, .failed, .cancelled]), ("Unknown", [.unknown]),
    ]

    var body: some View {
        ForEach(tree.sessions.filter { !$0.attention.isEmpty || $0.attentionDegraded }) { session in
            let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
            VStack(alignment: .leading, spacing: density.spacing(4)) {
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    Text("Copilot · \(session.shortID)").sidebarFont(.caption, weight: .semibold)
                }
                WorkStateLabel(state: session.state)
                SidebarActionLayout {
                    AttentionSummary(attention: session.attention, state: session.state, degraded: session.attentionDegraded)
                    AcknowledgeOutcomeButton(
                        attention: session.attention, sessionID: session.id, ownerID: nil,
                        degraded: session.attentionDegraded, acknowledge: acknowledge
                    )
                }
                ActivityDetail(activity: session.activity)
                Text("Process: \(session.liveness.rawValue)").font(.caption2).foregroundStyle(.secondary)
                if session.knownRunningChildren > 0 {
                    Text(SidebarCountText.runningChildren(session.knownRunningChildren, known: true)).font(.caption2).foregroundStyle(.blue)
                }
                AvailabilityPathRows(rootPath: paths.rootPath, projectRootPath: paths.projectRootPath)
                SurfacePathDetail(workingDirectory: paths.workingDirectory)
            }
            .padding(density.spacing(7))
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("taskboard-session-attention-\(session.id)")
        }
        if tree.sessions.allSatisfy({ $0.nodes.isEmpty }) {
            SidebarNotice(
                title: tree.hasCompleteCounts ? "No visible child tasks" : "Taskboard data unavailable",
                detail: "History controls may hide ended work; this does not mean the session is finished. The hierarchy remains available for workspace and session focus."
            )
        } else {
            ForEach(groups, id: \.0) { title, states in
                let sessions = tree.sessions.filter { session in session.nodes.contains { states.contains($0.state) } }
                if !sessions.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold))
                    ForEach(sessions) { session in
                        let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
                        ForEach(session.nodes.filter { states.contains($0.state) }) { node in
                            SidebarActionLayout {
                                FocusButton(
                                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                                    navigation: navigation, label: "Focus Copilot \(session.shortID), \(node.name)"
                                ) {
                                    VStack(alignment: .leading, spacing: density.spacing(4)) {
                                        CopilotChildLabel(node: node)
                                        Text("Copilot · \(session.shortID)").font(.caption2).foregroundStyle(.secondary)
                                        AvailabilityPathRows(rootPath: paths.rootPath, projectRootPath: paths.projectRootPath)
                                        SurfacePathDetail(workingDirectory: paths.workingDirectory)
                                    }
                                    .padding(density.spacing(7))
                                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .accessibilityValue(paths.accessibilityDescription)
                                DismissOutcomeButton(node: node, sessionID: session.id, dismiss: dismiss)
                                AcknowledgeOutcomeButton(
                                    attention: node.attention, sessionID: session.id, ownerID: node.id,
                                    degraded: node.attentionDegraded, acknowledge: acknowledge
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AttentionSummary: View {
    let attention: [AgentAttention]
    let state: CopilotWorkState
    let degraded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AgentAttentionKind.allCases.filter { kind in attention.contains { $0.kind == kind } }, id: \.self) { kind in
                let signals = attention.filter { $0.kind == kind }
                Label(kind.title + (signals.count > 1 ? " (\(signals.count))" : ""),
                      systemImage: kind.isBlocking ? "hand.raised" : "bell.badge")
                    .sidebarFont(.caption2).foregroundStyle(.orange)
                if kind == .turnFinished {
                    Text("Main turn only; background work may continue.")
                        .sidebarFont(.caption2).foregroundStyle(.secondary)
                }
                if signals.count == 1 {
                    if let date = signals.first?.occurredAt {
                        Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                            .sidebarFont(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Event time unknown").sidebarFont(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if state == .blocked && !attention.contains(where: { $0.kind.isBlocking }) {
                Text("Blocking reason unavailable").sidebarFont(.caption2).foregroundStyle(.orange)
            }
            if degraded {
                Text("Attention evidence incomplete").sidebarFont(.caption2).foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AcknowledgeOutcomeButton: View {
    let attention: [AgentAttention]
    let sessionID: UUID
    let ownerID: String?
    let degraded: Bool
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void

    var body: some View {
        let eligible = Set(SidebarCopilotTree.acknowledgeable(attention, sessionID: sessionID, ownerID: ownerID, degraded: degraded))
        if !eligible.isEmpty {
            Button("Acknowledge") { acknowledge(eligible) }
                .buttonStyle(.borderless).sidebarFont(.caption2)
                .help("Acknowledge this nonblocking outcome in Maestro only. No approval, answer or cancellation is sent.")
                .accessibilityIdentifier("acknowledge-outcome-\(sessionID)-\(ownerID.map { "child:\($0)" } ?? "primary")")
        }
    }
}

private struct ActivityDetail: View {
    let activity: AgentActivity?

    var body: some View {
        if let activity, let summary = activity.summary {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).lineLimit(2)
                if let date = activity.lastEventAt {
                    HStack(spacing: 3) {
                        Text("Recorded")
                        Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    }
                } else {
                    Text("Activity time unknown")
                }
            }
            .sidebarFont(.caption2).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct AvailabilityPathRows: View {
    let rootPath: HierarchyAvailability<String?>
    let projectRootPath: HierarchyAvailability<String?>

    var body: some View {
        switch (rootPath, projectRootPath) {
        case (.unavailable, _), (_, .unavailable):
            PermissionDetail(text: "Workspace paths unavailable")
        case (.available(let root), .available(let projectRoot)):
            VStack(alignment: .leading, spacing: 2) {
                PathDetail(label: "Workspace", path: root)
                PathDetail(label: "Project", path: projectRoot)
            }
        }
    }
}

private struct SurfacePathDetail: View {
    let workingDirectory: HierarchyAvailability<String?>

    var body: some View {
        switch workingDirectory {
        case .unavailable:
            PermissionDetail(text: workingDirectory.pathDisplayText)
        case .available(let path):
            PathDetail(label: "Path", path: path)
        }
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
            Text("\(label):")
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

private struct PermissionDetail: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock")
            .sidebarFont(.caption2)
            .foregroundStyle(.secondary)
    }
}

private struct FocusButton<Content: View>: View {
    let target: SidebarNavigationTarget
    let navigation: SidebarNavigation
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        Button { navigation.select(target) } label: { content.contentShape(Rectangle()) }
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
                .frame(width: density.controlSize - 2, height: density.controlSize)
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
        Label(state.title, systemImage: state.symbolName)
            .sidebarFont(.caption2)
            .foregroundStyle(state.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension CopilotWorkKind {
    var symbolName: String {
        switch self {
        case .subagent: "person.crop.circle"
        case .skill: "sparkles"
        case .shell: "terminal"
        case .unknown: "questionmark.square"
        }
    }
}

private extension CopilotWorkState {
    var title: String {
        switch self {
        case .working: "Working"
        case .idle: "Idle"
        case .blocked: "Blocked"
        case .completed: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "State unknown"
        }
    }
    var symbolName: String {
        switch self {
        case .working: "arrow.trianglehead.2.clockwise"
        case .idle: "pause.circle"
        case .blocked: "hand.raised"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .working: .blue
        case .idle, .cancelled, .unknown: .secondary
        case .blocked: .orange
        case .completed: .green
        case .failed: .red
        }
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
