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

struct SidebarView: View {
    // CMUX overlays 50 points of bottom chrome; the current SDK forwards no inset.
    private static let hostFooterClearance: CGFloat = 50
    let model: SidebarConnectionModel
    @Bindable private var preferences: SidebarPreferences
    @State private var showingHistory = false
    @State private var selectedManagedID: UUID?
    @State private var selectedUnmanaged: UnmanagedSelection?
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
            if model.copilot.tree.attentionOwnerCount > 0 {
                HStack {
                    Label(SidebarCountText.attention(model.copilot.tree.attentionOwnerCount), systemImage: "exclamationmark.circle")
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
                // Workspace rows already contain whole subtrees. Avoid lazy root
                // placement cycling during remote accessibility scrolling.
                VStack(alignment: .leading, spacing: preferences.layout.density.spacing(6)) {
                    outlineContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("sidebar-mode-content")

            selectionDetails

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

    @ViewBuilder private var outlineContent: some View {
        switch preferences.selectedMode {
        case .hierarchy:
            HierarchyContent(
                model: model, layout: preferences.layout,
                setExpanded: { preferences.setExpanded($1, for: $0) },
                dismiss: dismiss, acknowledge: acknowledge,
                managedSelection: Binding(
                    get: { selectedManagedID },
                    set: {
                        selectedManagedID = $0
                        if $0 != nil { selectedUnmanaged = nil }
                    }
                ),
                selection: Binding(
                    get: { selectedUnmanaged },
                    set: {
                        selectedUnmanaged = $0
                        if $0 != nil { selectedManagedID = nil }
                    }
                )
            )
        case .taskboard:
            if !model.orchestration.snapshot.nodes.isEmpty {
                ManagedHierarchyContent(
                    polling: model.orchestration, hierarchy: model.hierarchy,
                    navigation: model.navigation, layout: preferences.layout,
                    setExpanded: { preferences.setExpanded($1, for: $0) },
                    selectedID: Binding(
                        get: { selectedManagedID },
                        set: {
                            selectedManagedID = $0
                            if $0 != nil { selectedUnmanaged = nil }
                        }
                    )
                )
            }
            TaskboardContent(
                tree: model.copilot.tree, hierarchy: model.hierarchy,
                navigation: model.navigation, dismiss: dismiss, acknowledge: acknowledge
            )
        }
    }

    @ViewBuilder private var selectionDetails: some View {
        if let selectedManagedID,
           let selected = model.orchestration.snapshot.nodes.first(where: { $0.id == selectedManagedID }) {
            ManagedSelectionDetails(
                node: selected, hierarchy: model.hierarchy, tree: model.copilot.tree,
                availability: model.orchestration.availability,
                close: { self.selectedManagedID = nil }
            )
        } else if let selectedUnmanaged {
            UnmanagedSelectionDetails(
                selection: selectedUnmanaged,
                tree: model.copilot.tree,
                hierarchy: model.hierarchy,
                close: { self.selectedUnmanaged = nil }
            )
        }
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

private enum UnmanagedSelection: Equatable {
    case workspace(UUID)
    case surface(workspaceID: UUID, surfaceID: UUID)
    case session(UUID)
    case child(sessionID: UUID, childID: String)
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

    private func rows(for roots: [SidebarOrchestrationNode]) -> [ManagedDisplayNode] {
        var result: [ManagedDisplayNode] = []
        func append(_ node: SidebarOrchestrationNode, depth: Int) {
            let children = polling.children(of: node.id).sorted(by: sort)
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
                        WorkspaceOutlineHeader(workspace: group.workspace, navigation: navigation)
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
        Dictionary(grouping: polling.roots, by: \.workspaceId)
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
        polling.children(of: id).reduce(0) {
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
    let navigation: SidebarNavigation
    let toggleExpanded: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if hasChildren {
                ExpandButton(expanded: expanded, label: node.label, toggle: toggleExpanded)
            } else {
                Color.clear.frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
            }
            Button(action: select) {
                SidebarStateBadge(visual: stateVisual)
            }
            .buttonStyle(.plain)
            .help(stateVisual.title)
            .accessibilityLabel("\(node.label), \(stateVisual.title). Show details")
            .accessibilityIdentifier("select-managed-\(node.id)")
            FocusButton(
                target: .surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId),
                navigation: navigation, label: "Focus \(node.label)"
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(node.label).sidebarFont(.caption, weight: .medium).lineLimit(1)
                        Spacer(minLength: 0)
                        if activeDescendants > 0 && !expanded {
                            Label("\(activeDescendants)", systemImage: SidebarPresentation.state(.working).symbol)
                                .sidebarFont(.caption2).foregroundStyle(.secondary)
                                .help("\(activeDescendants) active descendant\(activeDescendants == 1 ? "" : "s")")
                        }
                    }
                    if let metadataLine {
                        HStack(spacing: 4) {
                            if !node.hasFreshGitEvidence(at: evidenceDate) {
                                Image(systemName: "clock")
                            }
                            Text(metadataLine).lineLimit(1).truncationMode(.middle)
                        }
                        .sidebarFont(.caption2)
                        .foregroundStyle(.secondary)
                        .help(node.hasFreshGitEvidence(at: evidenceDate) ? metadataLine
                              : "Last verified location, not current Git state: \(metadataLine)")
                        .accessibilityLabel(node.hasFreshGitEvidence(at: evidenceDate) ? metadataLine
                                            : "Last verified location: \(metadataLine). Current Git state unverified.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
            return "\(branch)  ·  \(worktree)"
        case let (branch?, _): return branch
        case let (_, worktree?): return worktree
        default: return nil
        }
    }

    private var stateVisual: SidebarVisual {
        SidebarPresentation.managedState(node, availability: availability, now: evidenceDate)
    }
}

private struct WorkspaceOutlineHeader: View {
        let workspace: HierarchyWorkspace?
        let navigation: SidebarNavigation

        var body: some View {
            if let workspace {
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

private struct ManagedSelectionDetails: View {
        let node: SidebarOrchestrationNode
        let hierarchy: HierarchySnapshot
        let tree: SidebarCopilotTree
        let availability: SidebarOrchestrationAvailability
        let close: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.label).sidebarFont(.caption, weight: .semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(SidebarPresentation.managedState(node, availability: availability, now: Date()).title)
                        .sidebarFont(.caption2).foregroundStyle(.secondary)
                    SidebarCloseButton(label: "Close agent details", id: "sidebar-close-details", action: close)
                }
                ScrollView {
                    SidebarMetadataDetails(lines: SidebarPresentation.managedNodeDetails(
                        node, hierarchy: hierarchy, tree: tree, now: Date()
                    ))
                }
                .frame(maxHeight: 180)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("managed-selection-details")
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
                    sessions: model.copilot.tree.sessions.filter { $0.workspaceID == workspace.id },
                    countsComplete: model.copilot.tree.hasCompleteCounts,
                    navigation: model.navigation, layout: layout, setExpanded: setExpanded,
                    orchestration: model.orchestration, hierarchy: model.hierarchy,
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
    @Binding var managedSelection: UUID?
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    @Environment(\.sidebarDensity) private var density
    private var expanded: Bool { layout.isExpanded(.workspace(workspace.id)) }
    private var managedNodes: [SidebarOrchestrationNode] {
        orchestration.snapshot.nodes.filter { $0.workspaceId == workspace.id }
    }
    private var unmanagedSessions: [SidebarCopilotSession] {
        let surfaces = Set(managedNodes.map(\.surfaceId))
        return sessions.filter { !surfaces.contains($0.surfaceID) }
    }
    private var summary: SidebarBranchSummary {
        var summary = SidebarBranchSummary(sessions: unmanagedSessions, complete: countsComplete)
        summary.include(managed: managedNodes, availability: orchestration.availability, now: Date())
        return summary
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
                if !expanded { CollapsedBranchSummary(summary: summary) }
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
            if expanded {
                if !managedNodes.isEmpty {
                    ManagedHierarchyContent(
                        polling: orchestration, hierarchy: hierarchy,
                        navigation: navigation, layout: layout, setExpanded: setExpanded,
                        selectedID: $managedSelection, workspaceID: workspace.id,
                        showsWorkspaceHeaders: false
                    )
                }
                switch workspace.surfaces {
                case .unavailable:
                    Text("Surface metadata unavailable").font(.caption2).foregroundStyle(.secondary)
                case .available(let surfaces) where surfaces.isEmpty:
                    Text("No shared surfaces").font(.caption2).foregroundStyle(.secondary)
                case .available(let surfaces):
                    ForEach(SidebarPresentation.unmanagedSurfaces(
                        surfaces, workspaceID: workspace.id, managed: managedNodes
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
                Button {
                    if let singleSession {
                        selection = .session(singleSession.id)
                    } else {
                        selection = .surface(workspaceID: workspaceID, surfaceID: surface.id)
                    }
                } label: {
                    if let singleSession {
                        SidebarStateBadge(visual: SidebarPresentation.sessionState(singleSession))
                    } else {
                        Image(systemName: surface.kind == .terminal || surface.kind == .agentSession
                              ? "circle.dashed" : surface.kind.symbolName)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 24)
                    }
                }
                .buttonStyle(.plain)
                .help(inspectionLabel)
                .accessibilityLabel(inspectionLabel)
                FocusButton(
                    target: .surface(workspaceID: workspaceID, surfaceID: surface.id),
                    navigation: navigation, label: "Focus \(surface.kind.title) \(title)"
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).sidebarFont(.caption, weight: .medium).lineLimit(1)
                        if let directoryLabel {
                            Text(directoryLabel).sidebarFont(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help("Working directory; Git branch not verified by this source")
                        }
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
                if let singleSession {
                    SessionEvidenceBadge(session: singleSession)
                }
                if !expanded && hasChildren {
                    CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: sessions, complete: countsComplete))
                }
                if surface.isPinned { StatusBadge(symbol: "pin.fill", label: "Pinned") }
                if surface.unreadCount > 0 { UnreadBadge(count: surface.unreadCount) }
            }
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
        return URL(fileURLWithPath: path).lastPathComponent
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
                    ExpandButton(expanded: expanded, label: "Copilot \(session.shortID)") {
                        setExpanded(.session(session.id), !expanded)
                    }
                } else {
                    Color.clear.frame(width: SidebarPresentation.minimumControlSize, height: SidebarPresentation.minimumControlSize)
                }
                Button {
                    selection = .session(session.id)
                } label: {
                    SidebarStateBadge(visual: SidebarPresentation.sessionState(session))
                }
                .buttonStyle(.plain)
                .help("\(SidebarPresentation.sessionState(session).title). Show details")
                .accessibilityLabel("Copilot \(session.shortID), \(SidebarPresentation.sessionState(session).title). Show details")
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Session \(session.shortID)").sidebarFont(.caption)
                        ActivityCaption(text: SidebarPresentation.activityCaption(
                            session.activity, runningShells: session.foldedShellCount(parentID: nil)
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityValue(session.state.rawValue)
                SessionEvidenceBadge(session: session)
                if !expanded && !session.outlineNodes.isEmpty {
                    CollapsedBranchSummary(summary: SidebarBranchSummary(sessions: [session]))
                }
            }
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
                AcknowledgeOutcomeButton(
                    attention: session.attention, sessionID: session.id, ownerID: nil,
                    degraded: session.attentionDegraded, acknowledge: acknowledge
                )
            }
            .padding(.leading, 28)
        }
        if session.omittedActiveChildrenCount > 0 {
            Text("\(session.omittedActiveChildrenCount) working/blocked tasks could not fit.")
                .sidebarFont(.caption).foregroundStyle(.orange)
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
            || !SidebarCopilotTree.acknowledgeable(
                node.attention, sessionID: session.id, ownerID: node.id,
                degraded: node.attentionDegraded
            ).isEmpty
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
                    SidebarStateBadge(visual: SidebarPresentation.state(node.state))
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
                        ActivityCaption(text: SidebarPresentation.activityCaption(
                            node.activity, runningShells: taskboard ? 0 : session.foldedShellCount(parentID: node.id)
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let summary = expansion?.collapsedSummary { CollapsedBranchSummary(summary: summary) }
                if node.ancestryUnresolved {
                    Image(systemName: "questionmark.circle")
                        .sidebarFont(.caption2).foregroundStyle(.orange)
                        .help("Unresolved ancestry")
                        .accessibilityLabel("Unresolved ancestry")
                }
                if hasOutcomeActions {
                    DismissOutcomeButton(node: node, sessionID: session.id, dismiss: dismiss)
                    AcknowledgeOutcomeButton(
                        attention: node.attention, sessionID: session.id, ownerID: node.id,
                        degraded: node.attentionDegraded, acknowledge: acknowledge, ownerLabel: node.name
                    )
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(taskboard ? "taskboard" : "copilot")-child-\(session.id)-\(node.id)")
    }
}

private struct UnmanagedSelectionDetails: View {
    let selection: UnmanagedSelection
    let tree: SidebarCopilotTree
    let hierarchy: HierarchySnapshot
    let close: () -> Void

    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(detail.title).sidebarFont(.caption, weight: .semibold).lineLimit(1)
                    Spacer()
                    SidebarCloseButton(label: "Close details", id: "sidebar-close-details", action: close)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        SidebarMetadataDetails(lines: detail.lines)
                        if case .session(let id) = selection,
                           let session = tree.sessions.first(where: { $0.id == id }),
                           !session.secondaryActivity.isEmpty {
                            DisclosureGroup("Other activity (\(session.secondaryActivity.count))") {
                                ForEach(session.secondaryActivity) { node in
                                    HStack {
                                        Text(node.name).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(SidebarPresentation.state(node.state).title).foregroundStyle(.secondary)
                                    }
                                    .sidebarFont(.caption2)
                                }
                            }
                            .sidebarFont(.caption)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("unmanaged-selection-details")
        }
    }

    private var detail: (title: String, lines: [SidebarDetailLine])? {
        switch selection {
        case .workspace(let id):
            guard let workspace = hierarchy.workspaces.first(where: { $0.id == id }) else { return nil }
            let title: String
            if case .available(let value) = workspace.title, !value.isEmpty {
                title = value
            } else {
                title = "Workspace"
            }
            return (title, [
                .init(title: "Workspace ID", value: workspace.id.uuidString),
                .init(title: "Workspace path", value: workspace.rootPath.pathDisplayText),
                .init(title: "Project path", value: workspace.projectRootPath.pathDisplayText)
            ])
        case .surface(let workspaceID, let surfaceID):
            guard let workspace = hierarchy.workspaces.first(where: { $0.id == workspaceID }),
                  case .available(let surfaces) = workspace.surfaces,
                  let surface = surfaces.first(where: { $0.id == surfaceID }) else { return nil }
            return (surface.title.isEmpty ? "Surface" : surface.title, [
                .init(title: "Type", value: surface.kind.title),
                .init(title: "Surface ID", value: surface.id.uuidString),
                .init(title: "Working directory", value: surface.workingDirectory.pathDisplayText)
            ])
        case .session(let id):
            guard let session = tree.sessions.first(where: { $0.id == id }) else { return nil }
            let paths = hierarchy.pathContext(
                workspaceID: session.workspaceID, surfaceID: session.surfaceID
            )
            return ("Copilot · \(session.shortID)",
                    SidebarPresentation.sessionDetails(session) + SidebarPresentation.paths(paths))
        case .child(let sessionID, let childID):
            guard let session = tree.sessions.first(where: { $0.id == sessionID }),
                  let node = session.nodes.first(where: { $0.id == childID }) else { return nil }
            let paths = hierarchy.pathContext(
                workspaceID: session.workspaceID, surfaceID: session.surfaceID
            )
            return (node.name,
                    SidebarPresentation.nodeDetails(node, session: session) + SidebarPresentation.paths(paths))
        }
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
                title: SidebarPresentation.emptyChildHistoryTitle(complete: tree.hasCompleteCounts),
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
                    Text("Copilot · \(session.shortID)").sidebarFont(.caption, weight: .semibold)
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
            ActivityCaption(text: SidebarPresentation.activityCaption(session.activity))
            if !session.childrenComplete || session.treeDegraded {
                Label("Children unavailable", systemImage: "info.circle")
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
                Label(text, systemImage: state == .blocked ? "pause.circle" : "exclamationmark.circle")
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
