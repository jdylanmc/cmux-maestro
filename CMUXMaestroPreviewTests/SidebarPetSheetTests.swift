import CoreGraphics
import Testing

struct SidebarPetSheetTests {
    @Test func acceptsStandardV2AndScaledSheets() {
        for (width, height) in [(1536, 1872), (1536, 2288), (3072, 3744), (768, 936), (1536, 2000)] {
            #expect(SidebarPetSheet.accepts(width: width, height: height), "\(width)x\(height)")
        }
    }

    @Test func rejectsSheetsWithoutTheGrid() {
        for (width, height) in [(1536, 1800), (1537, 1872), (400, 468), (5000, 6000), (1536, 4000), (0, 0)] {
            #expect(!SidebarPetSheet.accepts(width: width, height: height), "\(width)x\(height)")
        }
    }

    @Test func scaleIsRelativeToTheStandardWidthAndPlaybackStaysInTheFirstNineRows() {
        #expect(SidebarPetSheet.scale(width: 3072) == 2)
        for state in [SidebarPetState.idle, .working, .needsInput, .finished, .failed] {
            #expect(state.row < SidebarPetSheet.rows)
        }
    }
}
