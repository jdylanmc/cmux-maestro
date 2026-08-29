import SwiftUI

struct SidebarView: View {
    let model: SidebarConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Maestro")
                    .font(.headline)
                Text("CMUX connection preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
