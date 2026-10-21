import SwiftUI

/// Aggregate activity is a disclosure action, never a focus or acknowledgement action.
struct SidebarCollapsedActivityButton: View {
    let activity: SidebarWorkspaceSummary.Activity
    let expand: () -> Void

    var body: some View {
        SidebarTitleButton(label: activity.label, hint: activity.label, action: expand) {
            HStack(spacing: 4) {
                SidebarStateBadge(visual: activity.visual, needsInput: activity.needsInput)
                if activity.count > 1 {
                    Text(String(activity.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if activity.incomplete && activity.visual.symbol != "circle.dashed" {
                    SidebarStateBadge(visual: SidebarPresentation.state(.unknown))
                }
            }
            .frame(minWidth: SidebarPresentation.minimumControlSize,
                   minHeight: SidebarPresentation.minimumControlSize)
            .contentShape(Rectangle())
        }
        .fixedSize()
        .accessibilityIdentifier("collapsed-activity")
    }
}
