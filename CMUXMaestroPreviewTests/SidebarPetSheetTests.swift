import CoreGraphics
import Testing

struct SidebarPetSheetTests {
    @Test func acceptsStandardV2AndScaledSheets() {
        for (width, height) in [(1536, 1872), (1536, 2288), (3072, 3744), (768, 936), (1536, 2000),
                                (512, 1387), (776, 2102), (1536, 4160)] {
            #expect(SidebarPetSheet.accepts(width: width, height: height), "\(width)x\(height)")
        }
    }

    @Test func rejectsSheetsWithoutTheGrid() {
        for (width, height) in [(1536, 1800), (1537, 1872), (400, 468), (5000, 6000), (1536, 4000), (0, 0),
                                (1536, 4159), (1536, 4161), (1544, 4182), (3072, 8320),
                                (Int.max, Int.max), (Int.min, Int.min)] {
            #expect(!SidebarPetSheet.accepts(width: width, height: height), "\(width)x\(height)")
        }
    }

    @Test func scaleIsRelativeToTheStandardWidthAndPlaybackStaysInTheFirstNineRows() {
        #expect(SidebarPetSheet.scale(width: 3072) == 2)
        for mood in SidebarPetSheet.Mood.allCases {
            #expect((SidebarPetSheet.playback(for: mood, width: 1536, height: 1872)?.row ?? 99) < SidebarPetSheet.rows)
        }
    }

    @Test func moodRowsUseExplicitLegacyFallbacksAndTheirFullLoops() throws {
        let cases: [(SidebarPetSheet.Mood, Int, Int, Int, Int)] = [
            (.idle, 0, 6, 0, 6), (.thinking, 11, 6, 8, 6), (.working, 7, 6, 7, 6),
            (.delegating, 12, 8, 1, 8), (.question, 6, 6, 6, 6), (.needsPermission, 13, 6, 6, 6),
            (.confused, 14, 6, 8, 6), (.content, 3, 4, 3, 4), (.startled, 9, 5, 4, 5),
            (.sad, 5, 8, 5, 8), (.compacting, 15, 6, 2, 8), (.sleepy, 16, 6, 0, 6),
            (.gone, 17, 6, 0, 6), (.proud, 18, 4, 3, 4), (.celebrating, 19, 5, 4, 5)
        ]
        for (mood, row, count, fallback, fallbackCount) in cases {
            for height in [1872, 2000, 2288, 4160] {
                let playback = try #require(SidebarPetSheet.playback(for: mood, width: 1536, height: height))
                #expect(playback.row == (height == 4160 ? row : fallback))
                #expect(playback.frameCount == (height == 4160 ? count : fallbackCount))
            }
        }
        #expect(SidebarPetSheet.playback(for: .thinking, width: 1536, height: 4159) == nil)
    }

    @Test func insetScansFallbackLoopsAndExcludesReservedAndUnusedCells() {
        for (height, row, column) in [(1872, 2, 7), (2288, 4, 4), (4160, 9, 4), (4160, 19, 4)] {
            var pixels = [UInt8](repeating: 0, count: 1536 * height * 4)
            pixels[((row * 208 + 2) * 1536 + column * 192) * 4 + 3] = 255
            if height == 4160 {
                pixels[(10 * 208 * 1536) * 4 + 3] = 255
                pixels[((19 * 208) * 1536 + 5 * 192) * 4 + 3] = 255
            }
            let inset = pixels.withUnsafeBufferPointer {
                SidebarPetSheet.topInset(pixels: $0.baseAddress!, width: 1536, height: height, bytesPerRow: 1536 * 4)
            }
            #expect(inset == 2.0 / 208)
        }
    }

    @Test func scaledInsetUsesCumulativeRowOriginLikeCropping() {
        let width = 776, height = 2102
        let cellHeight = 208.0 * Double(width) / 1536
        let top = Int((17 * cellHeight).rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels[((top + 1) * width) * 4 + 3] = 255
        let inset = pixels.withUnsafeBufferPointer {
            SidebarPetSheet.topInset(pixels: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4)
        }
        #expect(abs(inset - 1 / cellHeight) < 0.000001)
    }
}
