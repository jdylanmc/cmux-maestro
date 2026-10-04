import Foundation

// Compile with -D PANEL_INPUT_PURE_CHECK and the two SidebarPanelInputOwnership*.swift test files.
// This entry point runs only value/geometry controls; never link the AppKit probe or launch its test host.
@main
struct SidebarPanelInputOwnershipCheck {
    static func main() {
        let failures = SidebarPanelInputOwnershipTests.failures()
        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print("PASS: strict companion positive, negative, boundary and cleanup controls (no AppKit)")
    }
}
