import Testing

struct SidebarPetSheetTests {
    @Test func acceptsStandardAndV2Sheets() {
        #expect(SidebarPetSheet.accepts(width: 1536, height: 1872))
        #expect(SidebarPetSheet.accepts(width: 1536, height: 2288))
    }

    @Test func rejectsOtherSizes() {
        for (width, height) in [(1536, 2000), (1920, 1872), (1536, 2080), (768, 936), (0, 0)] {
            #expect(!SidebarPetSheet.accepts(width: width, height: height))
        }
    }

    @Test func v2HeightIsElevenRowsAndPlaybackStaysInTheFirstNine() {
        #expect(SidebarPetSheet.v2Height == 2288)
        for state in [SidebarPetState.idle, .working, .needsInput, .finished, .failed] {
            #expect(state.row < SidebarPetSheet.rows)
        }
    }
}
