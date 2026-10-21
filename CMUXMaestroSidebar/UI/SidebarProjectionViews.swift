import SwiftUI

extension SidebarWorktreeGrouping {
    /// The current-worktree evidence of a managed agent's exact session: same session UUID,
    /// workspace and surface. A node without a recorded session has none.
    static func evidence(for node: SidebarOrchestrationNode, in tree: SidebarCopilotTree) -> AgentSessionWorktree? {
        guard let sessionID = node.copilotSessionId else { return nil }
        let session = (tree.sessions + tree.statusSessions).first {
            $0.id == sessionID && $0.workspaceID == node.workspaceId && $0.surfaceID == node.surfaceId
        }
        return session?.currentWorktree
    }
}

/// Worktrees or Sub-agents, for every workspace in every window.
struct SidebarProjectionPicker: View {
    @Binding var selection: SidebarProjection

    var body: some View {
        Picker("Grouping", selection: $selection) {
            ForEach(SidebarProjection.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Group agents by")
        .accessibilityIdentifier("sidebar-projection")
    }
}

/// One interactive agent in a collapsed group's icon card.
struct SidebarAgentIconCardItem: Identifiable {
    let id: String
    let title: String
    let workspaceID: UUID
    let surfaceID: UUID
    let iconTarget: SidebarIconTarget?
    let glyph: String?
    let color: SidebarAvatarColor?
    let visual: SidebarVisual
    let needsInput: Bool
    let hover: SidebarAgentHoverTarget?
    var inspection: SidebarInspection.Target? = nil
    var evidence: SidebarBranchSummary? = nil

    var status: String {
        ([SidebarPresentation.statusDescription(visual, needsInput: needsInput)]
            + (evidence.map(SidebarPresentation.collapsed) ?? [])).joined(separator: ". ")
    }

    var badge: SidebarVisual? {
        if needsInput || visual.tone == .red { return visual }
        if let evidence, evidence.attention > 0 {
            return .init(title: status, symbol: "exclamationmark.circle", tone: .attention)
        }
        if visual.tone != .neutral || !["circle", "checkmark.circle"].contains(visual.symbol) { return visual }
        return evidence?.incomplete == true ? SidebarPresentation.state(.unknown) : nil
    }

    @MainActor
    static func managed(
        _ node: SidebarOrchestrationNode, availability: SidebarOrchestrationAvailability,
        tree: SidebarCopilotTree, now: Date
    ) -> Self {
        let icon = SidebarPresentation.managedIcon(node, tree: tree, now: now)
        var item = Self(id: "managed-\(node.id)", title: node.title, workspaceID: node.workspaceId, surfaceID: node.surfaceId,
              iconTarget: SidebarPresentation.managedIconTarget(node, tree: tree, now: now),
              glyph: icon.glyph, color: icon.color,
              visual: SidebarPresentation.managedState(node, availability: availability, now: now, tree: tree),
              needsInput: SidebarPresentation.managedNeedsInput(node, tree: tree, now: now),
              hover: .managed(node.id, generation: node.generation), inspection: .managed(node))
        if case .session(let id) = item.iconTarget,
           let session = tree.exactLiveSession(id: id, workspaceID: node.workspaceId, surfaceID: node.surfaceId, now: now) {
            item.includeEvidence(session)
        }
        return item
    }

    static func session(_ session: SidebarCopilotSession, title: String) -> Self {
        var item = Self(id: "session-\(session.id)", title: title, workspaceID: session.workspaceID, surfaceID: session.surfaceID,
              iconTarget: session.statusOnly ? nil : .session(session.id),
              glyph: session.iconId, color: session.iconColor.flatMap(SidebarAvatarColor.init(rawValue:)),
              visual: SidebarPresentation.sessionState(session),
              needsInput: SidebarPresentation.needsInput(session.attention), hover: .session(session.id))
        item.includeEvidence(session)
        return item
    }

    private mutating func includeEvidence(_ session: SidebarCopilotSession) {
        var session = session
        session.attention = Self.visibleAttention(session.attention, state: session.state)
        // An icon's state belongs to its session, never to its descendants.
        session.nodes = []
        var summary = SidebarBranchSummary(sessions: [session])
        summary.running = 0
        summary.blocked = 0
        summary.incomplete = summary.incomplete || session.treeDegraded || summary.omittedActive > 0
        evidence = summary
    }

    static func visibleAttention(_ attention: [AgentAttention], state: AgentWorkState) -> [AgentAttention] {
        attention.filter { $0.kind != .turnFinished && !($0.kind == .error && state == .working) }
    }
}

/// A collapsed group: every agent's icon and state in one row that scrolls inside the card,
/// and a separate control that expands the group. Each icon focuses its agent's surface.
struct SidebarAgentIconCard: View {
    let items: [SidebarAgentIconCardItem]
    var retained: [SidebarCopilotSession] = []
    let navigation: SidebarNavigation
    let expandLabel: String
    let expand: () -> Void
    @Environment(SidebarPreferences.self) private var preferences
    @Environment(\.sidebarAgentIconStyle) private var agentStyle
    @Environment(\.sidebarTerminalIconStyle) private var terminalStyle

    var body: some View {
        let retainedState = Self.retainedState(retained)
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        FocusButton(
                            target: .surface(workspaceID: item.workspaceID, surfaceID: item.surfaceID),
                            navigation: navigation, label: "\(item.title), \(item.status)", detail: item.status,
                            inspection: item.inspection
                        ) {
                            icon(item)
                        }
                        .frame(width: 28, height: 28)
                        .agentHoverPreview(item.hover)
                        .accessibilityIdentifier("agent-icon-\(item.id)")
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.automatic, axes: .horizontal)
            .frame(height: 32)
            CollapsedBranchSummary(summary: retainedState.summary, compact: true, needsInput: retainedState.needsInput)
            Button(action: expand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expandLabel)
            .accessibilityLabel(expandLabel)
        }
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(items.count) agent\(items.count == 1 ? "" : "s")")
        .accessibilityIdentifier("agent-icon-card")
    }

    static func retainedState(_ sessions: [SidebarCopilotSession]) -> (summary: SidebarBranchSummary, needsInput: Bool) {
        let filtered = sessions.map { session in
            var session = session
            session.attention = SidebarAgentIconCardItem.visibleAttention(session.attention, state: session.state)
            for index in session.nodes.indices {
                session.nodes[index].attention = SidebarAgentIconCardItem.visibleAttention(
                    session.nodes[index].attention, state: session.nodes[index].state
                )
            }
            return session
        }
        let inputOwners = filtered.filter { SidebarPresentation.needsInput($0.attention) }.count
            + filtered.flatMap(\.nodes).filter { SidebarPresentation.needsInput($0.attention) }.count
        var summary = SidebarBranchSummary(sessions: filtered)
        // The parent row already shows its own activity; the card summarizes hidden work.
        summary.running -= filtered.filter { $0.state == .working }.count
        summary.blocked -= inputOwners
        summary.incomplete = summary.incomplete || filtered.contains { $0.treeDegraded || $0.hasUncountedChildren }
        return (summary, inputOwners > 0)
    }

    private func icon(_ item: SidebarAgentIconCardItem) -> some View {
        let choice = SidebarItemIcon.appearance(
            kind: .agent, target: item.iconTarget, agentGlyph: item.glyph, agentColor: item.color,
            icons: preferences.icons, agentStyle: agentStyle, terminalStyle: terminalStyle
        ).choice
        return SidebarGlyphIcon(name: choice.glyph, tint: Color(nsColor: choice.color.nativeColor))
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if let badge = item.badge {
                    SidebarStateBadge(visual: badge, needsInput: item.needsInput, detail: item.status)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.evidence?.incomplete == true, item.badge?.symbol != "circle.dashed" {
                    SidebarStateBadge(visual: SidebarPresentation.state(.unknown), detail: item.status)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                }
            }
    }
}

/// One Worktrees member: a managed agent, or a surface holding exactly one unmanaged Copilot session.
enum SidebarWorktreeMember: Identifiable {
    case managed(SidebarOrchestrationNode)
    case surface(HierarchySurface, SidebarCopilotSession)

    var id: UUID {
        switch self {
        case .managed(let node): node.id
        case .surface(let surface, _): surface.id
        }
    }

    func evidence(in tree: SidebarCopilotTree) -> AgentSessionWorktree? {
        switch self {
        case .managed(let node): SidebarWorktreeGrouping.evidence(for: node, in: tree)
        case .surface(_, let session): session.currentWorktree
        }
    }
}

/// One workspace's agents grouped by the worktree each exact session is in.
struct WorktreeProjectionContent: View {
    let workspaceID: UUID
    let members: [SidebarWorktreeMember]
    let tree: SidebarCopilotTree
    let orchestration: SidebarOrchestrationPolling
    let hierarchy: HierarchySnapshot
    let navigation: SidebarNavigation
    let layout: SidebarLayoutSettings
    let setExpanded: (SidebarExpansionID, Bool) -> Void
    @Binding var managedSelection: SidebarOrchestrationNode?
    let dismiss: (SidebarDismissedOutcome) -> Void
    let acknowledge: (Set<SidebarAcknowledgedOutcome>) -> Void
    @Binding var selection: UnmanagedSelection?
    let countsComplete: Bool
    /// The workspace's surface list: root agents and Copilot surfaces keep their saved order and moves.
    let surfaceOrder: SidebarReorderContext
    /// Managed agents with spawned children anywhere in the window.
    let parentIDs: Set<UUID>
    @Environment(\.sidebarPresentationNow) private var now

    var body: some View {
        let groups = SidebarWorktreeGrouping.groups(members) { $0.evidence(in: tree) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups) { group in
                let expansion = SidebarExpansionID.worktreeGroup(group.key, workspaceID: workspaceID)
                let expanded = layout.isExpanded(expansion)
                VStack(alignment: .leading, spacing: 2) {
                    WorktreeGroupHeader(group: group, expanded: expanded) { setExpanded(expansion, !expanded) }
                    if expanded {
                        // Moves and drops stay among this group's rows; groups have their own order.
                        let order = surfaceOrder.restricted(to: Set(group.members.map(surfaceID)))
                        ForEach(group.members) { member in row(member, order: order) }
                            .padding(.leading, 6)
                    } else {
                        SidebarAgentIconCard(
                            items: group.members.map(item), navigation: navigation,
                            expandLabel: "Expand \(group.title)"
                        ) { setExpanded(expansion, true) }
                        .padding(.leading, 18)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("worktree-group-\(group.key.storageID)")
            }
        }
    }

    private var managedIDs: Set<UUID> {
        Set(members.compactMap { if case .managed(let node) = $0 { node.id } else { nil } })
    }

    private func item(_ member: SidebarWorktreeMember) -> SidebarAgentIconCardItem {
        switch member {
        case .managed(let node):
            .managed(node, availability: orchestration.availability, tree: tree, now: now())
        case .surface(let surface, let session):
            .session(session, title: session.sessionName ?? (surface.title.isEmpty ? "Untitled surface" : surface.title))
        }
    }

    private func surfaceID(_ member: SidebarWorktreeMember) -> UUID {
        switch member {
        case .managed(let node): node.surfaceId
        case .surface(let surface, _): surface.id
        }
    }

    @ViewBuilder private func row(_ member: SidebarWorktreeMember, order: SidebarReorderContext) -> some View {
        switch member {
        case .managed(let node):
            // A spawned child whose parent is shown in this workspace moves with that parent.
            let child = node.parentId.map(managedIDs.contains) ?? false
            ManagedHierarchyContent(
                polling: orchestration, hierarchy: hierarchy, navigation: navigation, layout: layout,
                setExpanded: setExpanded, selectedNode: $managedSelection, dismiss: dismiss,
                acknowledge: acknowledge, selection: $selection, workspaceID: workspaceID,
                showsWorkspaceHeaders: false, displayNodes: [node], copilotTree: tree,
                surfaceOrder: child ? nil : order, movesWithParent: child,
                hasSpawnedChildren: parentIDs.contains(node.id)
            )
        case .surface(let surface, let session):
            SurfaceRow(
                workspaceID: workspaceID, surface: surface, reorder: order.handle(for: surface.id, noun: "surface"),
                sessions: [session], countsComplete: countsComplete, navigation: navigation, layout: layout,
                setExpanded: setExpanded, dismiss: dismiss, acknowledge: acknowledge, selection: $selection
            )
        }
    }
}

private struct WorktreeGroupHeader: View {
    let group: SidebarWorktreeGroup<SidebarWorktreeMember>
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                if group.identity != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(.system(size: density.rowTitleSize, weight: .semibold))
                        .lineLimit(1)
                    if let detail = group.detail {
                        Text(detail)
                            .font(.system(size: density.rowMetadataSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if group.isLastKnown {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Last known")
                        .accessibilityLabel("Last known")
                }
                Text("\(group.members.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(group.members.count) agent\(group.members.count == 1 ? "" : "s")")
            }
            .frame(minHeight: SidebarPresentation.minimumControlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([group.title, group.detail].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel([group.title, group.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }
}

/// An interactive agent row's one line: name, tag chips (#51), state. No subtitle.
struct SidebarAgentTitleLine<Badge: View>: View {
    let title: String
    let tags: [SidebarResolvedTag]
    @ViewBuilder var badge: Badge
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        HStack(spacing: 4) {
            SidebarTaggedTitle(tags: tags) {
                Text(title).font(.system(size: density.rowTitleSize, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            badge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
