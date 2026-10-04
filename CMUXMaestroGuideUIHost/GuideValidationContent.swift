import SwiftUI

@MainActor
struct GuideValidationContent: View {
    @State private var minimalCount = 0
    @State private var copyCount = 0
    @State private var model = CLIIntegrationGuideModel(read: {
        .checked(CLIIntegrationGuideReader.relativePaths.map {
            .init(relativePath: $0, content: .missing)
        })
    })

    var body: some View {
        VStack(spacing: 12) {
            Text(verbatim: "Synthetic validation only - no installed guide or clipboard access")
            VStack {
                Button(action: { minimalCount += 1 }) {
                    Text(verbatim: "Synthetic minimal button")
                }
                .accessibilityIdentifier("guide-validation-minimal-button")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("guide-validation-minimal-root")

            Text(verbatim: "Synthetic minimal count: \(minimalCount)")
                .accessibilityIdentifier("guide-validation-minimal-count")
            Text(verbatim: "Synthetic copy count: \(copyCount)")
                .accessibilityIdentifier("guide-validation-copy-count")

            VStack {
                CLIIntegrationSettingsView(model: model, copyCommand: {
                    CLIIntegrationGuide.copyInstallCommand(write: { _ in
                        copyCount += 1
                        return true
                    })
                })
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("guide-validation-real-guide-root")
        }
        .padding(16)
        .overlay(alignment: .topLeading) {
            // Overlay keeps this fully clipped negative control out of the guide's layout.
            VStack {
                Button(action: { minimalCount += 1 }) {
                    Text(verbatim: "Re-check")
                }
                .accessibilityIdentifier("guide-validation-clipped-button")
                .offset(y: 1_000)
            }
            .frame(width: 180, height: 28)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("guide-validation-clipped-root")
        }
        .preferredColorScheme(.light)
    }
}
