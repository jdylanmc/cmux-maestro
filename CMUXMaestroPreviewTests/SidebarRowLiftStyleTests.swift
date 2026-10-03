import Testing

struct SidebarRowLiftStyleTests {
    @Test(arguments: [false, true], [false, true])
    func excludedRowsNeverLift(hovered: Bool, keyboardFocused: Bool) {
        #expect(!SidebarRowLiftStyle.isLifted(
            eligible: false, hovered: hovered, keyboardFocused: keyboardFocused
        ))
    }

    @Test func focusAndHoverHandOffWithoutChangingTheSingleSurface() {
        let transitions = [
            (hovered: false, keyboardFocused: false, lifted: false),
            (hovered: true, keyboardFocused: false, lifted: true),
            (hovered: true, keyboardFocused: true, lifted: true),
            (hovered: false, keyboardFocused: true, lifted: true),
            (hovered: false, keyboardFocused: false, lifted: false)
        ]
        for state in transitions {
            #expect(SidebarRowLiftStyle.isLifted(
                eligible: true, hovered: state.hovered, keyboardFocused: state.keyboardFocused
            ) == state.lifted)
        }
    }

    @Test func pointerSelectionAloneIsNotALiftInput() {
        #expect(!SidebarRowLiftStyle.isLifted(eligible: true, hovered: false, keyboardFocused: false))
        #expect(SidebarRowLiftStyle.highlightOpacity == 0.04)
        #expect(SidebarRowLiftStyle.duration == 0.160)
        #expect(SidebarRowLiftStyle.nearShadowOpacity == 0.10)
        #expect(SidebarRowLiftStyle.farShadowOpacity == 0.06)
    }
}
