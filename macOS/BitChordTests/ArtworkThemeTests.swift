import Foundation
import XCTest

final class ArtworkThemeTests: XCTestCase {
    func testPaletteUsesDominantCoverColorVibrantAccentAndBottomEdgeWash() throws {
        let width = 10
        let height = 10
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)

        for index in 0..<(width * height) {
            if index < 80 {
                rgba += [48, 78, 104, 255] // dominant muted blue
            } else {
                rgba += [240, 105, 20, 255] // smaller vivid orange bottom edge
            }
        }

        let colors = try XCTUnwrap(
            ArtworkThemeExtractor.colors(fromRGBA: rgba, width: width, height: height)
        )

        XCTAssertEqual(colors.background.lightness, 0.13, accuracy: 0.01)
        XCTAssertEqual(
            colors.background.hue,
            ArtworkRGB(red: UInt8(48), green: UInt8(78), blue: UInt8(104)).hue,
            accuracy: 0.03
        )
        XCTAssertEqual(
            colors.accent.hue,
            ArtworkRGB(red: UInt8(240), green: UInt8(105), blue: UInt8(20)).hue,
            accuracy: 0.03
        )
        XCTAssertGreaterThanOrEqual(colors.accent.saturation, 0.55)
        XCTAssertEqual(colors.accent.lightness, 0.62, accuracy: 0.01)
        XCTAssertEqual(colors.wash.hue, colors.accent.hue, accuracy: 0.03)
        XCTAssertEqual(colors.wash.lightness, 0.24, accuracy: 0.01)
    }

    func testPaletteRejectsMalformedPixelBuffers() {
        XCTAssertNil(ArtworkThemeExtractor.colors(fromRGBA: [], width: 0, height: 0))
        XCTAssertNil(ArtworkThemeExtractor.colors(fromRGBA: [0, 0, 0, 255], width: 2, height: 2))
    }
}
