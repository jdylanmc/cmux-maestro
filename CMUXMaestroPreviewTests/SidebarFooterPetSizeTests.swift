import CoreGraphics
import Testing

struct SidebarFooterPetSizeTests {
    private let baseline = SidebarFooterPetSize.baselineWidth
    /// Laid-out height per point of width: the 208:192 cell less its trimmed top band.
    private let layoutAspect: CGFloat = 189 / 192

    @Test func autoHeightFooterKeepsBaselineWidth() {
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 400, userSized: false) == baseline)
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 0, userSized: true) == baseline)
    }

    @Test func growsWithUserSizedBodyHeight() {
        let short = SidebarFooterPetSize.width(bodyHeight: 42, footerWidth: 400, userSized: true)
        let tall = SidebarFooterPetSize.width(bodyHeight: 55, footerWidth: 400, userSized: true)
        #expect(short > baseline && tall > short)
        #expect(tall == (55 / layoutAspect).rounded(.down))
    }

    @Test func cappedByHalfFooterWidth() {
        #expect(SidebarFooterPetSize.width(bodyHeight: 1_000, footerWidth: 100, userSized: true) == 50)
        #expect(SidebarFooterPetSize.width(bodyHeight: 1_000, footerWidth: 101, userSized: true) == 50)
    }

    @Test func fitsSixtyFourPointBox() {
        let width = SidebarFooterPetSize.width(bodyHeight: 1_000, footerWidth: 2_000, userSized: true)
        #expect(width == (64 * 192 / 208).rounded(.down))
        #expect(width <= 64 && width * SidebarFooterPetSize.aspect <= 64)
    }

    @Test func cappedByBodyHeightKeepingAspect() {
        for body: CGFloat in [42, 57.5, 90, 180, 333] {
            let width = SidebarFooterPetSize.width(bodyHeight: body, footerWidth: 2_000, userSized: true)
            #expect(width == width.rounded(.down) && width >= baseline)
            #expect(SidebarFooterPetSize.height(forWidth: width) <= body)
        }
        #expect(abs(SidebarFooterPetSize.height(forWidth: 192) - 189) < 0.001)
    }

    @Test func baselineFloorUnlessFooterIsNarrowerThanTwiceIt() {
        #expect(SidebarFooterPetSize.width(bodyHeight: 10, footerWidth: 400, userSized: true) == baseline)
        #expect(SidebarFooterPetSize.width(bodyHeight: .infinity, footerWidth: 400, userSized: true) == baseline)
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 76, userSized: true) == baseline)
        // Hard containment wins: half of a sub-76pt footer is below the baseline.
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 60, userSized: true) == 30)
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 40, userSized: false) == 20)
    }

    @Test func shrinksWhenSidebarNarrowsOrBodyShortens() {
        let wide = SidebarFooterPetSize.width(bodyHeight: 300, footerWidth: 340, userSized: true)
        let narrow = SidebarFooterPetSize.width(bodyHeight: 300, footerWidth: 100, userSized: true)
        let shorter = SidebarFooterPetSize.width(bodyHeight: 45, footerWidth: 340, userSized: true)
        #expect(wide == 59 && narrow == 50 && shorter == (45 / layoutAspect).rounded(.down))
    }
}
