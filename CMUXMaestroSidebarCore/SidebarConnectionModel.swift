import Observation

/// Observable connection health used by `SidebarView`.
///
/// The model consumes plain `SidebarConnectionSignal` values so the extension
/// entry point owns the only CMUX ExtensionKit dependency.
@Observable
@MainActor
final class SidebarConnectionModel {
    private(set) var state: SidebarConnectionState = SidebarConnectionReducer.initialState

    func apply(_ signal: SidebarConnectionSignal) {
        state = SidebarConnectionReducer.reduce(state, signal)
    }
}
