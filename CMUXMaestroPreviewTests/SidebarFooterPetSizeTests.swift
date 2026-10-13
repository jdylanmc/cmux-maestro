import CoreGraphics
import Testing

struct SidebarFooterPetSizeTests {
    private let baseline = SidebarFooterPetSize.baselineWidth

    @Test func autoHeightFooterKeepsBaselineWidth() {
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 400, userSized: false) == baseline)
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 0, userSized: true) == baseline)
    }

    @Test func growsWithUserSizedBodyHeight() {
        let short = SidebarFooterPetSize.width(bodyHeight: 60, footerWidth: 400, userSized: true)
        let tall = SidebarFooterPetSize.width(bodyHeight: 120, footerWidth: 400, userSized: true)
        #expect(short > baseline && tall > short)
        #expect(tall == (120 * 192 / 208).rounded(.down))
    }

    @Test func cappedByHalfFooterWidth() {
        #expect(SidebarFooterPetSize.width(bodyHeight: 1_000, footerWidth: 240, userSized: true) == 120)
        #expect(SidebarFooterPetSize.width(bodyHeight: 1_000, footerWidth: 241, userSized: true) == 120)
    }

    @Test func cappedByBodyHeightKeepingAspect() {
        for body: CGFloat in [42, 57.5, 90, 180, 333] {
            let width = SidebarFooterPetSize.width(bodyHeight: body, footerWidth: 2_000, userSized: true)
            #expect(width == width.rounded(.down))
            #expect(SidebarFooterPetSize.height(forWidth: width) <= body || width == baseline)
        }
        #expect(abs(SidebarFooterPetSize.height(forWidth: 192) - 208) < 0.001)
    }

    @Test func neverBelowBaseline() {
        #expect(SidebarFooterPetSize.width(bodyHeight: 10, footerWidth: 400, userSized: true) == baseline)
        #expect(SidebarFooterPetSize.width(bodyHeight: 400, footerWidth: 40, userSized: true) == baseline)
        #expect(SidebarFooterPetSize.width(bodyHeight: .infinity, footerWidth: 400, userSized: true) == baseline)
    }

    @Test func shrinksWhenSidebarNarrowsOrBodyShortens() {
        let wide = SidebarFooterPetSize.width(bodyHeight: 300, footerWidth: 340, userSized: true)
        let narrow = SidebarFooterPetSize.width(bodyHeight: 300, footerWidth: 240, userSized: true)
        let shorter = SidebarFooterPetSize.width(bodyHeight: 100, footerWidth: 240, userSized: true)
        #expect(wide == 170 && narrow == 120 && shorter == 92)
    }
}
