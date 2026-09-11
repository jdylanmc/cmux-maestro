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

            ModeContent(mode: preferences.selectedMode)

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

    var body: some View {
        switch mode {
        case .hierarchy:
            PlaceholderPanel(
                title: "Hierarchy",
                detail: "Hierarchy content will appear here in a future update."
            )
        case .taskboard:
            PlaceholderPanel(
                title: "Taskboard",
                detail: "Taskboard content will appear here in a future update."
            )
        }
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
