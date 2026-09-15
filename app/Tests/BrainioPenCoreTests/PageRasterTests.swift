import Foundation
@testable import BrainioPenCore
import XCTest

/// The image the agent reads is cropped to the writing and scaled to be legible. Both are
/// arithmetic, and both are wrong in ways nobody notices by eye — a page that is slightly too small
/// simply transcribes a little worse — so they are pinned here.
final class PageRasterTests: XCTestCase {
    private let page = PageID(surface: "s3/o27/b450", page: 4)!
    private let palette = Palette(ink: ["black": "#1a1a1a", "red": "#ff0200"],
                                  widthMM: ["default": 0.5])

    private func stroke(_ dots: [(Double, Double, Double)], tip: TipType = .pen, start: Int = 0) -> Stroke {
        Stroke(page: page, start: start, end: start + 10, tip: tip,
               dots: dots.map { DotSample(x: $0.0, y: $0.1, force: $0.2, dt: 0) },
               source: .live, penMac: "M", firmware: "F")
    }

    private func black(_ ms: Int) -> (ink: InkColor, width: LineWidth) { (.black, .default) }

    func testAnEmptyPageDrawsNothing() {
        XCTAssertNil(PageRaster.make(strokes: [], palette: palette, state: black))
    }

    func testAPageOfEraserMarksDrawsNothing() {
        let rubbed = stroke([(10, 10, 0.5), (12, 10, 0.5)], tip: .eraser)
        XCTAssertNil(PageRaster.make(strokes: [rubbed], palette: palette, state: black))
    }

    func testTheImageIsTheWritingPlusAMarginNotTheWholeSheet() throws {
        // Two centimetres of writing in the middle of an A4 sheet.
        let mm = PageGeometry.mmPerCell
        let one = stroke([(20 / mm, 100 / mm, 0.5), (40 / mm, 100 / mm, 0.5)])
        let raster = try XCTUnwrap(PageRaster.make(strokes: [one], palette: palette, state: black))

        // 20 mm of ink, 6 mm of white on each side, and a flat line: the short side is the pad.
        let scale = PageRaster.minPx / 32.0
        XCTAssertEqual(Double(raster.widthPx), (32.0 * scale).rounded(), accuracy: 1)
        XCTAssertEqual(Double(raster.heightPx), (12.0 * scale).rounded(), accuracy: 1)
        // Nothing like the 210 mm the sheet is wide: 32 mm of it, drawn to be read.
        XCTAssertLessThan(Double(raster.widthPx), PageRaster.maxPx)
    }

    func testAFullSheetIsCappedRatherThanDrawnAtFullResolution() throws {
        let mm = PageGeometry.mmPerCell
        let across = stroke([(10 / mm, 10 / mm, 0.5), (200 / mm, 280 / mm, 0.5)])
        let raster = try XCTUnwrap(PageRaster.make(strokes: [across], palette: palette, state: black))
        XCTAssertEqual(Double(max(raster.widthPx, raster.heightPx)), PageRaster.maxPx, accuracy: 1)
    }

    func testPressingHarderDrawsAWiderLine() throws {
        let one = stroke([(10, 10, 0.2), (12, 10, 0.9)])
        let raster = try XCTUnwrap(PageRaster.make(strokes: [one], palette: palette, state: black))
        let points = try XCTUnwrap(raster.lines.first?.points)
        XCTAssertLessThan(points[0].width, points[1].width)
        XCTAssertGreaterThan(points[0].width, 0)
    }

    func testTheColourComesFromTheModeLogNotFromTheStroke() throws {
        // The pen reports black for everything; what was in force is what decides (ADR-DRAFT).
        let one = stroke([(10, 10, 0.5), (12, 10, 0.5)])
        let raster = try XCTUnwrap(PageRaster.make(strokes: [one], palette: palette,
                                                   state: { _ in (.red, .default) }))
        XCTAssertEqual(raster.lines.first?.hex, "#ff0200")
    }

    func testAnUnmeasuredInkDrawsBlackRatherThanNothing() throws {
        let one = stroke([(10, 10, 0.5), (12, 10, 0.5)])
        let raster = try XCTUnwrap(PageRaster.make(strokes: [one], palette: palette,
                                                   state: { _ in (.green, .default) }))
        XCTAssertEqual(raster.lines.first?.hex, "#000000")
    }

    func testALineIsNeverThinnerThanOnePixel() throws {
        let faint = stroke([(10, 10, 0.0), (10.2, 10, 0.0)])
        let raster = try XCTUnwrap(PageRaster.make(strokes: [faint], palette: Palette(ink: [:]), state: black))
        for point in try XCTUnwrap(raster.lines.first?.points) {
            XCTAssertGreaterThanOrEqual(point.width, 1)
        }
    }
}
