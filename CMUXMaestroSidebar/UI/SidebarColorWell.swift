import SwiftUI

struct SidebarColorWell: NSViewRepresentable {
    let color: NSColor
    let label: String
    let edit: SidebarColorEdit?
    let choose: (SidebarTagColor) -> Void
    let unavailable: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarNativeColorWell {
        SidebarNativeColorWell(frame: .zero)
    }

    func updateNSView(_ well: SidebarNativeColorWell, context: Context) {
        well.configure(color: color, label: label, choose: choose, unavailable: unavailable)
        edit?.attach(well)
    }

    static func dismantleNSView(_ well: SidebarNativeColorWell, coordinator: ()) { well.cancel() }
}
