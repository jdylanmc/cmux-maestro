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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "pet.mood.label", defaultValue: "Pet \(name), \(description)"))
            .help(description)
            .onChange(of: input, initial: true) { _, value in display.update(value) }
            .onDisappear { display.stop() }
    }
}
