import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("CMUX Maestro Preview", systemImage: "sidebar.left")
                .font(.title2.weight(.semibold))

            Text("Containing app for the sandboxed CMUX sidebar extension.")
                .foregroundStyle(.secondary)

            ForEach(PreviewConnectionState.allCases, id: \.self) { state in
                StatusCard(state: state)
            }

            Text("Extension: com.jdylanmc.CMUXMaestroPreview.Extension")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
    }
}

private struct StatusCard: View {
    let state: PreviewConnectionState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbolName)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .fontWeight(.semibold)
                Text(state.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var color: Color {
        switch state {
        case .waiting:
            .secondary
        case .connected:
            .green
        case .degraded:
            .orange
        }
    }
}

#Preview {
    ContentView()
}
