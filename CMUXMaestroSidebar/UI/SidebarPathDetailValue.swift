import SwiftUI

struct SidebarPathDetailValue: View {
    let line: SidebarDetailLine
    let copy: (String) -> Bool
    var focusChanged: (Bool) -> Void = { _ in }
    var inlineWhenShort = false
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var compactHeight: CGFloat = 0

    private var overflows: Bool {
        line.path?.isAvailable == true && compactHeight > 0 && fullHeight > compactHeight + 0.5
    }

    private var font: Font { inlineWhenShort ? .caption2 : .caption }

    var body: some View {
        Group {
            if inlineWhenShort && !overflows {
                Text("\(line.title): \(line.value)")
                    .font(font).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("\(line.title): \(line.value)" + (line.help.map { ". \($0)" } ?? ""))
                    .accessibilityLabel("\(line.title): \(line.value)")
            } else {
                labeledValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            // Measure the same text/font at the actual proposed width, not character count.
            Text(line.value).font(font).lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden().accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            Text(verbatim: "Ag\nAg\nAg").font(font).lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .hidden().accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { compactHeight = $0 }
        }
        .accessibilityHint(line.help ?? "")
        .onChange(of: overflows) { if !overflows { expanded = false } }
    }

    private var labeledValue: some View {
        SidebarLabeledValue(
            label: line.title, value: line.value, clipboardValue: line.copyableValue,
            copy: copy, focusChanged: focusChanged, font: font
        ) {
            Text(line.value)
                .textSelection(.enabled)
                .lineLimit(line.path?.isAvailable == true && !expanded ? 3 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sidebar-path-value")
        } trailing: {
            Spacer(minLength: overflows ? 8 : 0)
            SidebarPathDisclosureButton(
                label: line.title, expanded: expanded, available: overflows,
                toggle: { expanded.toggle() }, focusChanged: focusChanged
            )
            .frame(width: overflows ? 24 : 0, height: overflows ? 24 : 0)
        }
        .help(line.help ?? "")
    }
}
