import SwiftUI

struct SidebarView: View {
    let model: SidebarConnectionModel
    @Bindable private var preferences: SidebarPreferences

    init(model: SidebarConnectionModel, preferences: SidebarPreferences) {
        self.model = model
        self.preferences = preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maestro").font(.headline)
            Picker("Sidebar view", selection: $preferences.selectedMode) {
                ForEach(SidebarMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Sidebar view")

            CopilotOverview(tree: model.copilot.tree)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    switch preferences.selectedMode {
                    case .hierarchy:
                        HierarchyContent(model: model)
                    case .taskboard:
                        TaskboardContent(tree: model.copilot.tree, hierarchy: model.hierarchy, navigation: model.navigation)
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
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
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
                Text("\(tree.sessions.count) Copilot sessions")
                    .font(.subheadline.weight(.semibold))
                if tree.hasCompleteCounts {
                    Text("\(tree.knownRunningChildren) child tasks running")
                        .font(.caption)
                } else if tree.knownRunningChildren > 0 {
                    Text("At least \(tree.knownRunningChildren) known child tasks running")
                        .font(.caption)
                } else {
                    Text("Running child count unavailable")
                        .font(.caption)
                }
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
                    navigation: model.navigation
                )
            }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: HierarchyWorkspace
    let sessions: [SidebarCopilotSession]
    let navigation: SidebarNavigation
    @State private var expanded = true

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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ExpandButton(expanded: $expanded, label: title)
                FocusButton(target: .workspace(workspace.id), navigation: navigation, label: "Focus workspace \(title)") {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
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
                            sessions: sessions.filter { $0.surfaceID == surface.id }, navigation: navigation
                        )
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-\(workspace.id.uuidString)")
    }
}

private struct SurfaceRow: View {
    let workspaceID: UUID
    let surface: HierarchySurface
    let sessions: [SidebarCopilotSession]
    let navigation: SidebarNavigation
    @State private var expanded = true

    private var title: String { surface.title.isEmpty ? "Untitled surface" : surface.title }
    private var accessibilityStatus: String {
        var labels: [String] = []
        if surface.isFocused { labels.append("Focused") }
        if surface.isPinned { labels.append("Pinned") }
        if surface.unreadCount > 0 { labels.append("\(surface.unreadCount) unread") }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if !sessions.isEmpty { ExpandButton(expanded: $expanded, label: title) }
                FocusButton(
                    target: .surface(workspaceID: workspaceID, surfaceID: surface.id),
                    navigation: navigation, label: "Focus \(surface.kind.title) \(title)"
                ) {
                    HStack(spacing: 5) {
                        Image(systemName: surface.kind.symbolName)
                        Text(title).font(.caption.weight(.medium)).lineLimit(2)
                        Spacer(minLength: 0)
                        if surface.isFocused { StatusBadge(symbol: "scope", label: "Focused") }
                        if surface.isPinned { StatusBadge(symbol: "pin.fill", label: "Pinned") }
                        if surface.unreadCount > 0 { UnreadBadge(count: surface.unreadCount) }
                    }
                }
                .accessibilityValue(accessibilityStatus)
            }
            SurfacePathDetail(workingDirectory: surface.workingDirectory)
            if expanded {
                ForEach(sessions) { session in
                    CopilotSessionRow(session: session, navigation: navigation)
                }
            }
        }
        .padding(6)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surface-\(surface.id.uuidString)")
    }
}

private struct CopilotSessionRow: View {
    let session: SidebarCopilotSession
    let navigation: SidebarNavigation
    @State private var expanded = true
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                ExpandButton(expanded: $expanded, label: "Copilot \(session.shortID)")
                FocusButton(
                    target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                    navigation: navigation, label: "Focus Copilot session \(session.shortID)"
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Copilot · \(session.shortID)").font(.caption.weight(.semibold))
                        WorkStateLabel(state: session.state)
                        Text(session.model ?? "Model unknown").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityValue("\(session.state.rawValue), \(session.model ?? "model unknown"), process \(session.liveness.rawValue)")
            }
            Text("Process: \(session.liveness.rawValue)")
                .font(.caption2).foregroundStyle(.secondary)
            if session.knownRunningChildren > 0 {
                Label("\(session.knownRunningChildren) known child tasks running", systemImage: "arrow.trianglehead.2.clockwise")
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
            if expanded {
                if session.nodes.isEmpty {
                    Text(session.childrenComplete ? "No recorded child tasks" : "Child history unavailable or loading")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(session.visibleNodes(collapsed: collapsed)) { node in
                    if node.ancestryUnresolved && node.parentID == nil {
                        Label("Unresolved ancestry", systemImage: "questionmark.folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        if node.hasChildren {
                            ExpandButton(
                                expanded: Binding(
                                    get: { !collapsed.contains(node.id) },
                                    set: { value in
                                        if value { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                                    }
                                ),
                                label: node.name
                            )
                        }
                        FocusButton(
                            target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                            navigation: navigation, label: "Focus \(node.name), \(node.state.rawValue), Copilot \(session.shortID)"
                        ) {
                            CopilotChildLabel(node: node)
                        }
                    }
                    .padding(.leading, CGFloat(node.depth + (node.ancestryUnresolved ? 1 : 0)) * 4)
                    .accessibilityIdentifier("copilot-child-\(session.id)-\(node.id)")
                }
                if !session.childrenComplete {
                    Text(session.treeDegraded ? "Child tree incomplete; no completion is inferred for missing items." : "Partial child history; missing tasks are not assumed finished.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copilot-session-\(session.id)")
        .help("Copilot session \(session.id.uuidString)")
    }
}

private struct CopilotChildLabel: View {
    let node: SidebarCopilotNode
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(node.name, systemImage: node.kind.symbolName)
                .font(.caption).lineLimit(2)
            WorkStateLabel(state: node.state)
            if let model = node.model {
                Text(model).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskboardContent: View {
    let tree: SidebarCopilotTree
    let hierarchy: HierarchySnapshot
    let navigation: SidebarNavigation

    private let groups: [(String, [CopilotWorkState])] = [
        ("Blocked", [.blocked]), ("Working", [.working]), ("Idle", [.idle]),
        ("Done / ended", [.completed, .failed, .cancelled]), ("Unknown", [.unknown]),
    ]

    var body: some View {
        if tree.sessions.allSatisfy({ $0.nodes.isEmpty }) {
            SidebarNotice(
                title: tree.hasCompleteCounts ? "No recorded child tasks" : "Taskboard data unavailable",
                detail: "Taskboard groups contain observed Copilot child work only. The hierarchy remains available for workspace and session focus."
            )
        } else {
            ForEach(groups, id: \.0) { title, states in
                let sessions = tree.sessions.filter { session in session.nodes.contains { states.contains($0.state) } }
                if !sessions.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold))
                    ForEach(sessions) { session in
                        let paths = hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID)
                        ForEach(session.nodes.filter { states.contains($0.state) }) { node in
                            FocusButton(
                                target: .surface(workspaceID: session.workspaceID, surfaceID: session.surfaceID),
                                navigation: navigation, label: "Focus Copilot \(session.shortID), \(node.name)"
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    CopilotChildLabel(node: node)
                                    Text("Copilot · \(session.shortID)").font(.caption2).foregroundStyle(.secondary)
                                    AvailabilityPathRows(rootPath: paths.rootPath, projectRootPath: paths.projectRootPath)
                                    SurfacePathDetail(workingDirectory: paths.workingDirectory)
                                }
                                .padding(7)
                                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .accessibilityValue(paths.accessibilityDescription)
                        }
                    }
                }
            }
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
        .font(.caption2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(displayText)")
    }
}

private struct PermissionDetail: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock")
            .font(.caption2)
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
    @Binding var expanded: Bool
    let label: String
    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2).frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(label)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

private struct WorkStateLabel: View {
    let state: CopilotWorkState
    var body: some View {
        Label(state.title, systemImage: state.symbolName)
            .font(.caption2)
            .foregroundStyle(state.color)
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
