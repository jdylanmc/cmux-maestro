import SwiftUI

struct SidebarBacklogEditor: View {
    let workspaceID: UUID
    let windowID: UUID?
    let title: String
    @Environment(SidebarPreferences.self) private var preferences
    @Environment(SidebarBacklog.self) private var backlog
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirmingReset = false

    private var current: Bool { backlog.contains(workspaceID: workspaceID, windowID: windowID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Workspace backlog")).font(.headline)
            Text(title).font(.subheadline).lineLimit(2)
            Text(workspaceID.uuidString).font(.caption2).textSelection(.enabled)
            TextField(String(localized: "Backlog URL"), text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("backlog-url")
                .onSubmit { save() }
            Text(String(localized: "Only this workspace identity uses this URL. A replacement workspace starts unconfigured. Saving does not open a browser."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !current {
                Text(SidebarBacklog.Status.unavailable.message).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = preferences.backlogNotice {
                Text(notice).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Reset all backlog settings...")) { confirmingReset = true }
                    .confirmationDialog(String(localized: "Remove all saved workspace backlog URLs?"),
                                        isPresented: $confirmingReset) {
                        Button(String(localized: "Reset all backlog settings"), role: .destructive) {
                            preferences.resetBacklogs()
                            if preferences.backlogNotice == nil { text = "" }
                        }
                    }
            }
            HStack {
                Button(String(localized: "Remove URL")) { text = ""; save() }
                    .disabled(!current || preferences.backlog.urlText(for: workspaceID) == nil)
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) { save() }
                    .disabled(!current).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            preferences.refreshBacklogs()
            text = preferences.backlog.urlText(for: workspaceID) ?? ""
        }
    }

    private func save() {
        guard current else { return }
        preferences.setBacklogURL(text, for: workspaceID)
        if preferences.backlogNotice == nil { dismiss() }
    }
}
