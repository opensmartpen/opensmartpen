import OpenSmartPenCore
@testable import OpenSmartPenUI
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// The page image is the one drawing nobody ever looks at: it goes straight to a model. So the two
/// things that can be silently wrong about it — which way up it is, and whether there is any ink on
/// it at all — are asserted here, in pixels.
final class PageImageTests: XCTestCase {
    private let page = PageID(surface: "s3/o27/b450", page: 1)!

    /// A page that is plainly heavier at the top: a long line across the top, and one short mark
    /// near the bottom. Upside down, the weight moves to the other half — which is the whole test.
    private func raster() -> PageRaster {
        let across = Stroke(page: page, start: 0, end: 10,
                            dots: (0...50).map { DotSample(x: 10 + Double($0), y: 10, force: 0.9, dt: 4) },
                            source: .live, penMac: "M", firmware: "F")
        let mark = Stroke(page: page, start: 20, end: 30,
                          dots: [DotSample(x: 10, y: 60, force: 0.9, dt: 0),
                                 DotSample(x: 13, y: 60, force: 0.9, dt: 8)],
                          source: .live, penMac: "M", firmware: "F")
        return PageRaster.make(strokes: [across, mark],
                               palette: Palette(ink: ["black": "#000000"], widthMM: ["default": 0.8]),
                               state: { _ in (.black, .default) })!
    }

    /// Dark pixels per row, counted from the top of the image down.
    ///
    /// A bitmap context keeps row 0 at the top in memory, whichever way its drawing coordinates
    /// run — so this reads the image as a person would see it, and no compensating flip is applied
    /// here. One in the test would hide exactly the fault the test is for.
    private func darkPerRow(_ data: Data) throws -> (height: Int, rows: [Int]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = (0..<height).map { row in
            (0..<width).filter { buffer[(row * width + $0) * 4] < 128 }.count
        }
        return (height, rows)
    }

    func testThereIsInkOnThePage() throws {
        let drawn = try darkPerRow(try XCTUnwrap(PageImage.png(raster())))
        XCTAssertGreaterThan(drawn.rows.reduce(0, +), 0, "a page with strokes on it has dark pixels")
    }

    /// The fault the first real page found: paper counts y down from the top and Core Graphics
    /// counts it up from the bottom, so the page was drawn upside down — and handwriting flipped
    /// about its own line still looks like handwriting, so only the transcriber noticed.
    func testThePageIsTheRightWayUp() throws {
        let drawn = try darkPerRow(try XCTUnwrap(PageImage.png(raster())))
        let half = drawn.height / 2
        let top = drawn.rows[0..<half].reduce(0, +)
        let bottom = drawn.rows[half...].reduce(0, +)
        XCTAssertGreaterThan(top, bottom * 3,
                             "the long line is written near the top of the page, so the top half "
                                 + "must hold most of the ink (top \(top), bottom \(bottom))")
    }
}
