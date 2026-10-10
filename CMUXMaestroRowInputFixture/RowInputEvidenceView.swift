import AppKit

/// AX reads sample state; they never refresh focus or invoke a product action.
final class RowInputEvidenceView: NSTextField {
    var observe: () -> String = { "unconfigured" }

    override func accessibilityValue() -> String? { observe() }
}
