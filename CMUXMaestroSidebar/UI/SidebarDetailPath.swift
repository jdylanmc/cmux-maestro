import Foundation

/// Source-owned semantics; neither labels nor Copy availability classify a path.
struct SidebarDetailPath: Equatable {
    enum Field: String {
        case workspace, project, surfaceDirectory, parentSurfaceDirectory
    }

    let field: Field
    let isAvailable: Bool
}
