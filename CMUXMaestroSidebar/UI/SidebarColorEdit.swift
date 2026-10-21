import Observation

/// An editor ends its own native color edit before reading its draft or closing with Done.
@Observable
@MainActor
final class SidebarColorEdit {
    private weak var well: SidebarNativeColorWell?

    func attach(_ well: SidebarNativeColorWell) { self.well = well }
    func finish() { well?.finish() }
    func reset(_ action: () -> Void) {
        well?.cancel()
        action()
    }
}
