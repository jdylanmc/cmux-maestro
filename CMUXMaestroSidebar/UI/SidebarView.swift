import SwiftUI

struct SidebarView: View {
    let model: SidebarConnectionModel
    @Bindable private var preferences: SidebarPreferences

    init(model: SidebarConnectionModel, preferences: SidebarPreferences) {
        self.model = model
        self.preferences = preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Maestro")
                    .font(.headline)
                Text("CMUX connection preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Sidebar view", selection: $preferences.selectedMode) {
                    ForEach(SidebarMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Sidebar view")
                .padding(.top, 7)
            }

            ModeContent(mode: preferences.selectedMode, hierarchy: model.hierarchy)

            switch model.state {
            case .waiting:
                StatePanel(
                    title: "Waiting for CMUX",
                    detail: "The sidebar is ready. Waiting for the host connection and first snapshot.",
                    symbolName: "clock",
                    color: .secondary,
                    showsProgress: true
                )
            case .connected(let workspaceCount, let surfaceCount):
                StatePanel(
                    title: "Connected",
                    detail: "\(workspaceCount) workspaces and \(surfaceCount) surfaces are available from CMUX.",
                    symbolName: "checkmark.circle.fill",
                    color: .green
                )
            case .degraded(let message):
                StatePanel(
                    title: "Connection degraded",
                    detail: message,
                    symbolName: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }

            Spacer()

            Text("Provider data is not enabled in this bootstrap.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("sidebar-banner-region")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ModeContent: View {
    let mode: SidebarMode
    let hierarchy: HierarchySnapshot

    var body: some View {
        switch mode {
        case .hierarchy:
            HierarchyContent(snapshot: hierarchy)
        case .taskboard:
            PlaceholderPanel(
                title: "Taskboard",
                detail: "Taskboard content will appear here in a future update."
            )
        }
    }
}

private struct HierarchyContent: View {
    let snapshot: HierarchySnapshot

    var body: some View {
        Group {
            if !snapshot.receivedSnapshot {
                HierarchyNotice(
                    title: "Waiting for hierarchy",
                    detail: "CMUX has not delivered the first shared workspace snapshot."
                )
            } else if !snapshot.workspaceListAvailable {
                HierarchyNotice(
                    title: "Workspace list unavailable",
                    detail: "CMUX has not granted access to the shared workspace list."
                )
            } else if snapshot.workspaces.isEmpty {
                HierarchyNotice(
                    title: "No shared workspaces",
                    detail: "CMUX is connected, but this snapshot contains no shared workspaces."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.workspaces) { workspace in
                            WorkspaceRow(workspace: workspace)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("sidebar-mode-content")
    }
}

private struct WorkspaceRow: View {
    let workspace: HierarchyWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            workspaceHeader

            if case .available(let detail) = workspace.detail, let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AvailabilityPathRows(
                rootPath: workspace.rootPath,
                projectRootPath: workspace.projectRootPath
            )

            switch workspace.surfaces {
            case .unavailable:
                PermissionDetail(text: "Surface metadata unavailable")
            case .available(let surfaces) where surfaces.isEmpty:
                PermissionDetail(text: "No shared surfaces")
            case .available(let surfaces):
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(surfaces) { surface in
                        SurfaceRow(surface: surface)
                    }
                }
                .padding(.leading, 10)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-\(workspace.id.uuidString)")
    }

    private var workspaceHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)

            switch workspace.title {
            case .available(let title):
                Text(title.isEmpty ? "Workspace title not provided" : title)
                    .font(.subheadline.weight(.semibold))
            case .unavailable:
                Text("Workspace metadata unavailable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

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
}

private struct SurfaceRow: View {
    let surface: HierarchySurface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: surface.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(surface.title.isEmpty ? "Surface title not provided" : surface.title)
                        .font(.caption.weight(.medium))
                    Text(surface.kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if surface.isFocused {
                    StatusBadge(symbol: "scope", label: "Focused")
                }
                if surface.isPinned {
                    StatusBadge(symbol: "pin.fill", label: "Pinned")
                }
                if surface.unreadCount > 0 {
                    UnreadBadge(count: surface.unreadCount)
                }
            }

            switch surface.workingDirectory {
            case .unavailable:
                PermissionDetail(text: "Path unavailable")
            case .available(let path):
                PathDetail(label: "Path", path: path)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surface-\(surface.id.uuidString)")
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

private struct PathDetail: View {
    let label: String
    let path: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(label):")
                .foregroundStyle(.tertiary)
            Text(path ?? "No path shared")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path ?? "No path shared")
        }
        .font(.caption2)
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
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("\(count) unread")
    }
}

private struct HierarchyNotice: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PlaceholderPanel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar-mode-content")
    }
}

private struct StatePanel: View {
    let title: String
    let detail: String
    let symbolName: String
    let color: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbolName)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
