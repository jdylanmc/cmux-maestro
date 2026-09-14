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

private extension SidebarTone {
    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .purple: .purple
        case .pink: .pink
        case .amber: .orange
        case .green: .green
        case .red: .red
        case .neutral: .secondary
        }
    }
}

struct SidebarKindIcon: View {
    let visual: SidebarVisual
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(systemName: visual.symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(visual.tone.color)
            .frame(width: 26, height: 26)
            .background(visual.tone.color.opacity(contrast == .increased ? 0.24 : 0.12),
                        in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(visual.title)
            .help(visual.title)
    }
}

struct SidebarStateBadge: View {
    let visual: SidebarVisual
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Label(visual.title, systemImage: visual.symbol)
            .sidebarFont(.caption2, weight: .medium)
            .foregroundStyle(visual.tone.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(visual.tone.color.opacity(contrast == .increased ? 0.20 : 0.10),
                        in: RoundedRectangle(cornerRadius: 5))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(visual.title)
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
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarPresentation.collapsed(summary), id: \.self) { line in Text(line) }
        }
        .sidebarFont(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Collapsed branch. \(SidebarPresentation.collapsed(summary).joined(separator: ". "))")
    }
}

struct SidebarView: View {
    // The current CMUX host overlays bottom controls without forwarding an SDK inset.
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
            content.environment(\.sidebarContentWidth, max(0, geometry.size.width - preferences.layout.density.spacing(20)))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: preferences.layout.density.spacing(6)) {
            HStack {
                Text("Maestro").font(.headline)
                Spacer()
                Button { showingHistory.toggle() } label: {
                    Image(systemName: "gearshape")
                        .frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
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
                    if !model.copilot.tree.acknowledgeableOutcomes.isEmpty {
                        Button("Acknowledge all") { acknowledge(model.copilot.tree.acknowledgeableOutcomes) }
                            .buttonStyle(.borderless).font(.caption)
                            .frame(minHeight: SidebarPresentation.minimumControlSize)
                            .help("Acknowledge nonblocking outcomes on current-window surfaces. Never answers or approves a request.")
                            .accessibilityIdentifier("sidebar-acknowledge-all")
                    }
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
                LazyVStack(alignment: .leading, spacing: preferences.layout.density.spacing(6)) {
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
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            Button("Reset history settings") {
                preferences.resetHistory()
                model.copilot.updateHistory(preferences.history)
            }
            Divider()
            Text("Attention").font(.headline)
            Text("Local only; never approves or answers requests. Turn finished does not mean background work ended.")
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
            Text("CMUX connected")
                .font(.caption2).foregroundStyle(.secondary)
        case .degraded:
            Label("CMUX disconnected. Focus and live status unavailable.", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
        }
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
                    .sidebarFont(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
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
    @State private var showingDetails = false
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
        VStack(alignment: .leading, spacing: density.spacing(4)) {
            HStack(spacing: 5) {
                ExpandButton(expanded: expanded, label: title) {
                    setExpanded(.workspace(workspace.id), !expanded)
                }
                FocusButton(target: .workspace(workspace.id), navigation: navigation, label: "Focus workspace \(title)") {
                    HStack(spacing: 5) {
                        SidebarKindIcon(visual: SidebarPresentation.workspace)
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
                SidebarDetailsButton(expanded: $showingDetails, label: title, id: "details-workspace-\(workspace.id)")
            }
            if let path = SidebarPresentation.briefPath(root: workspace.rootPath, project: workspace.projectRootPath) {
                PathDetail(label: "Path", path: path)
                    .padding(.leading, 34)
            }
            if showingDetails {
                SidebarMetadataDetails(lines: [
                    .init(title: "Workspace", value: title),
                    .init(title: "Workspace ID", value: workspace.id.uuidString),
                    .init(title: "Workspace path", value: workspace.rootPath.pathDisplayText),
                    .init(title: "Project path", value: workspace.projectRootPath.pathDisplayText)
                ])
            }
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
        .padding(.vertical, density.spacing(4))
        .padding(.horizontal, 4)
        .background {
            if case .available(true) = workspace.isSelected {
                RoundedRectangle(cornerRadius: 7).fill(.blue.opacity(0.06))
            }
        }
        .overlay(alignment: .leading) {
            if case .available(true) = workspace.isSelected {
                RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 2)
            }
        }
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
    @State private var showingDetails = false
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
        VStack(alignment: .leading, spacing: density.spacing(4)) {
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
                        SidebarKindIcon(visual: SidebarPresentation.surface(surface.kind))
                        Text(title).sidebarFont(.caption, weight: .medium).lineLimit(2)
                        Spacer(minLength: 0)
                        if surface.isFocused { StatusBadge(symbol: "scope", label: "Focused") }
                        if surface.isPinned { StatusBadge(symbol: "pin.fill", label: "Pinned") }
                        if surface.unreadCount > 0 { UnreadBadge(count: surface.unreadCount) }
                    }
                }
                .accessibilityValue(accessibilityStatus)
                SidebarDetailsButton(expanded: $showingDetails, label: title, id: "details-surface-\(surface.id)")
            }
            if showingDetails {
                SidebarMetadataDetails(lines: [
                    .init(title: "Surface", value: title),
                    .init(title: "Type", value: surface.kind.title),
                    .init(title: "Surface ID", value: surface.id.uuidString),
                    .init(title: "Working directory", value: surface.workingDirectory.pathDisplayText)
                ])
            }
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
        .padding(.leading, density.spacing(8))
        .padding(.vertical, density.spacing(2))
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 2)
        }
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
    @State private var showingDetails = false
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
                    HStack(spacing: 6) {
                        SidebarKindIcon(visual: SidebarPresentation.session)
                        Text("Copilot · \(session.shortID)").sidebarFont(.caption, weight: .semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityValue(session.state.rawValue)
                SidebarDetailsButton(expanded: $showingDetails, label: "Copilot \(session.shortID)", id: "details-session-\(session.id)")
            }
            SidebarActionLayout {
                SessionStateSummary(session: session)
                AcknowledgeOutcomeButton(
                    attention: session.attention, sessionID: session.id, ownerID: nil,
                    degraded: session.attentionDegraded, acknowledge: acknowledge
                )
            }
            AttentionSummary(attention: session.attention, state: session.state, degraded: session.attentionDegraded)
            ExecutingActivity(activity: session.activity)
            if showingDetails { SidebarMetadataDetails(lines: SidebarPresentation.sessionDetails(session)) }
            if !session.childrenComplete || session.treeDegraded {
                Label("Children unavailable", systemImage: "ellipsis.circle")
                    .sidebarFont(.caption2).foregroundStyle(.secondary)
                    .help("Child history incomplete; missing work is not assumed finished")
            }
            if session.omittedActiveChildrenCount > 0 {
                Text("\(session.omittedActiveChildrenCount) working/blocked tasks could not fit.")
                    .sidebarFont(.caption).foregroundStyle(.orange)
            }
            if !expanded {
                CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: [session]))
            }
            if expanded {
                if session.nodes.isEmpty && session.childrenComplete {
                    Text("No visible child tasks")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(session.childRows(layout: layout)) { row in
                    let node = row.node
                    CopilotWorkRow(
                        node: node, session: session, navigation: navigation, dismiss: dismiss, acknowledge: acknowledge,
                        expansion: row, setExpanded: setExpanded
                    )
                    .padding(.leading, density.indentation(depth: node.depth, unresolved: node.ancestryUnresolved, width: contentWidth))
                }
            }
        }
        .padding(.vertical, density.spacing(4))
        .padding(.leading, density.spacing(8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copilot-session-\(session.id)")
        .help("Copilot session \(session.id.uuidString)")
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
    @Environment(\.sidebarDensity) private var density
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(3)) {
            HStack(alignment: .top, spacing: 4) {
                if let expansion, node.hasChildren, let setExpanded {
                    ExpandButton(expanded: expansion.expanded, label: node.name) {
                        setExpanded(expansion.expansionID, !expansion.expanded)
                    }
                }
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus \(node.name), \(node.state.rawValue), Copilot \(session.shortID)"
                ) {
                    HStack(spacing: 6) {
                        SidebarKindIcon(visual: SidebarPresentation.work(node.kind))
                        Text(node.name).sidebarFont(.caption, weight: .medium).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                SidebarDetailsButton(expanded: $showingDetails, label: node.name, id: "details-child-\(session.id)-\(node.id)")
            }
            SidebarActionLayout {
                WorkStateLabel(state: node.state)
                DismissOutcomeButton(node: node, sessionID: session.id, dismiss: dismiss)
                AcknowledgeOutcomeButton(
                    attention: node.attention, sessionID: session.id, ownerID: node.id,
                    degraded: node.attentionDegraded, acknowledge: acknowledge, ownerLabel: node.name
                )
            }
            AttentionSummary(attention: node.attention, state: node.state, degraded: node.attentionDegraded)
            ExecutingActivity(activity: node.activity)
            if node.ancestryUnresolved {
                Label("Unresolved ancestry", systemImage: "questionmark.folder").sidebarFont(.caption).foregroundStyle(.orange)
            }
            if node.historyAncestor {
                Text("Child context").sidebarFont(.caption2).foregroundStyle(.secondary)
            } else if node.state.isTerminal && node.terminalTimestamp == nil {
                Text("Completion age unknown").sidebarFont(.caption2).foregroundStyle(.secondary)
            }
            if showingDetails {
                SidebarMetadataDetails(lines: SidebarPresentation.nodeDetails(node, session: session)
                    + (paths.map(SidebarPresentation.paths) ?? []))
            }
            if let summary = expansion?.collapsedSummary { CollapsedBranchSummary(summary: summary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, density.spacing(3))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(taskboard ? "taskboard" : "copilot")-child-\(session.id)-\(node.id)")
    }
}

private struct DismissOutcomeButton: View {
    let node: SidebarCopilotNode
    let sessionID: UUID
    let dismiss: (SidebarDismissedOutcome) -> Void

    var body: some View {
        if let outcome = node.dismissibleOutcome(sessionID: sessionID) {
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
    @Environment(\.sidebarDensity) private var density

    private let groups: [(String, [CopilotWorkState])] = [
        ("Blocked", [.blocked]), ("Working", [.working]), ("Idle", [.idle]),
        ("Done / ended", [.completed, .failed, .cancelled]), ("Unknown", [.unknown]),
    ]

    var body: some View {
        ForEach(tree.sessions) { session in
            let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
            TaskboardSessionRow(session: session, paths: paths, navigation: navigation, acknowledge: acknowledge)
        }
        if tree.sessions.allSatisfy({ $0.nodes.isEmpty }) {
            SidebarNotice(
                title: tree.hasCompleteCounts ? "No visible child tasks" : "Taskboard data unavailable",
                detail: "History may hide ended work; this does not mean the session is finished. Workspace focus remains in Hierarchy."
            )
        } else {
            ForEach(groups, id: \.0) { title, states in
                let sessions = tree.sessions.filter { session in session.nodes.contains { states.contains($0.state) } }
                if !sessions.isEmpty {
                    if let state = states.first {
                        Label(title, systemImage: SidebarPresentation.state(state).symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SidebarPresentation.state(state).tone.color)
                    }
                    ForEach(sessions) { session in
                        let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
                        Text("Copilot · \(session.shortID)").sidebarFont(.caption).foregroundStyle(.secondary)
                        ForEach(session.nodes.filter { states.contains($0.state) }) { node in
                            CopilotWorkRow(
                                node: node, session: session, navigation: navigation, dismiss: dismiss,
                                acknowledge: acknowledge, paths: paths, taskboard: true
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
    let paths: HierarchyPathContext
    let navigation: SidebarNavigation
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    HStack(spacing: 6) {
                        SidebarKindIcon(visual: SidebarPresentation.session)
                        Text("Copilot · \(session.shortID)").sidebarFont(.caption, weight: .semibold)
                    }
                }
                Spacer(minLength: 0)
                SidebarDetailsButton(expanded: $showingDetails, label: "Copilot \(session.shortID)", id: "details-session-\(session.id)")
            }
            SidebarActionLayout {
                SessionStateSummary(session: session)
                AcknowledgeOutcomeButton(
                    attention: session.attention, sessionID: session.id, ownerID: nil,
                    degraded: session.attentionDegraded, acknowledge: acknowledge
                )
            }
            AttentionSummary(attention: session.attention, state: session.state, degraded: session.attentionDegraded)
            ExecutingActivity(activity: session.activity)
            if !session.childrenComplete || session.treeDegraded {
                Label("Children unavailable", systemImage: "ellipsis.circle")
                    .sidebarFont(.caption2).foregroundStyle(.secondary)
                    .help("Child history incomplete; missing work is not assumed finished")
            }
            if showingDetails {
                SidebarMetadataDetails(lines: SidebarPresentation.sessionDetails(session) + SidebarPresentation.paths(paths))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("taskboard-session-attention-\(session.id)")
    }
}

private struct AttentionSummary: View {
    let attention: [AgentAttention]
    let state: CopilotWorkState
    let degraded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarPresentation.attention(attention, state: state, degraded: degraded), id: \.self) { text in
                Label(text, systemImage: state == .blocked ? "hand.raised" : "bell.badge")
                    .sidebarFont(.caption).foregroundStyle(.orange)
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
    var ownerLabel: String? = nil

    var body: some View {
        let eligible = Set(SidebarCopilotTree.acknowledgeable(attention, sessionID: sessionID, ownerID: ownerID, degraded: degraded))
        if !eligible.isEmpty {
            Button("Acknowledge") { acknowledge(eligible) }
                .buttonStyle(.borderless).sidebarFont(.caption)
                .frame(minHeight: SidebarPresentation.minimumControlSize)
                .help("Acknowledge this nonblocking outcome in Maestro only. No approval, answer or cancellation is sent.")
                .accessibilityLabel("Acknowledge \(ownerLabel ?? ownerID ?? "Copilot \(sessionID.uuidString.prefix(8))"), nonblocking outcome")
                .accessibilityIdentifier("acknowledge-outcome-\(sessionID)-\(ownerID.map { "child:\($0)" } ?? "primary")")
        }
    }
}

private struct ExecutingActivity: View {
    let activity: AgentActivity?

    var body: some View {
        if let activity, activity.kind == .executing, let summary = activity.summary {
            Text(summary).sidebarFont(.caption).foregroundStyle(.secondary).lineLimit(1).help(summary)
        }
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
    func focus() { navigation.select(target) }

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
        SidebarStateBadge(visual: SidebarPresentation.state(state))
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
