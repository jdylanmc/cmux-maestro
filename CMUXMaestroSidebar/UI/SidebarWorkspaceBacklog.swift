import SwiftUI

struct SidebarWorkspaceBacklog: ViewModifier {
    let workspaceID: UUID
    let windowID: UUID?
    let title: String
    let groups: [SidebarRowActionGroup]
    @Environment(SidebarPreferences.self) private var preferences
    @Environment(SidebarBacklog.self) private var backlog
    @State private var editing = false

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                content
                Button(action: open) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(backlog.pending != nil)
                .accessibilityLabel(String(localized: "Open workspace backlog"))
                .accessibilityValue(preferences.backlog.urlText(for: workspaceID) == nil
                    ? String(localized: "Not configured") : String(localized: "Configured"))
                .accessibilityIdentifier("backlog-\(workspaceID)")
                .help(preferences.backlog.urlText(for: workspaceID) == nil
                    ? SidebarBacklog.Status.missingURL.message
                    : String(localized: "Open this workspace's backlog in a new right-hand CMUX browser split."))
            }
            .sidebarRowActions(title: "workspace \(title)", groups: groups + [
                .init(title: String(localized: "Backlog"), actions: [
                    .init(title: String(localized: "Open backlog"), unavailable: backlog.pending == nil ? nil
                          : SidebarBacklog.Status.opening.message, perform: open),
                    .init(title: String(localized: "Configure backlog URL..."), perform: {
                        preferences.refreshBacklogs()
                        // Native menu tracking must end before presenting the editor.
                        Task { @MainActor in editing = true }
                    })
                ])
            ])
        }
        .popover(isPresented: $editing) {
            SidebarBacklogEditor(workspaceID: workspaceID, windowID: windowID, title: title)
        }
    }

    private func open() {
        preferences.refreshBacklogs()
        guard preferences.backlogNotice == nil else { editing = true; return }
        let text = preferences.backlog.urlText(for: workspaceID)
        backlog.open(workspaceID: workspaceID, windowID: windowID, urlText: text)
        if text == nil { editing = true }
    }
}

extension View {
    func sidebarWorkspaceBacklog(
        workspaceID: UUID, windowID: UUID?, title: String, groups: [SidebarRowActionGroup]
    ) -> some View {
        modifier(SidebarWorkspaceBacklog(workspaceID: workspaceID, windowID: windowID, title: title, groups: groups))
    }
}
