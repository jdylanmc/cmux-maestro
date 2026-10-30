import SwiftUI

/// Holds only sprite art. The surrounding status and attention continue to use current evidence.
struct SidebarMoodPetView: View {
    let store: SidebarPetStore
    let petID: String
    let session: UUID?
    let input: SidebarPetMoodInput
    var width: CGFloat = 46
    var topTrim: CGFloat = 0
    @State private var display = SidebarPetMoodDisplay()

    var body: some View {
        let current = display.current ?? SidebarPetMood.resolve(input, now: Date())
        let shown = display.shown ?? current
        let description = SidebarPetMoodDisplay.description(shown: shown, current: current)
        let name = store.descriptor(petID, session: session)?.displayName ?? "Maestro"
        SidebarPetView(store: store, petID: petID, session: session, mood: shown.mood, width: width,
                       topTrim: topTrim)
            .overlay { if shown.isPreview { SidebarMoodPreviewGlyph(width: width) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "pet.mood.label", defaultValue: "Pet \(name), \(description)"))
            .help(description)
            .onChange(of: input, initial: true) { _, value in display.update(value) }
            .onDisappear { display.stop() }
    }
}

/// Marks a cosmetic preview from the art's quiet top-left corner; the pet's label and help carry the words.
struct SidebarMoodPreviewGlyph: View {
    let width: CGFloat
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        // Pet art and playback symbols do not mirror, so the corner stays physically top-left.
        Image(systemName: "play.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .font(.system(size: min(max(width * 0.24, 9), 14), weight: .semibold))
            .background(Circle().fill(.background).padding(-1))
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: direction == .rightToLeft ? .topTrailing : .topLeading)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
