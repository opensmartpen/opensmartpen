import OpenSmartPenCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a worked-out page into a PNG. Everything decided — the crop, the scale, the width of each
/// line — was decided in `PageRaster`; this only draws it.
///
/// Core Graphics does the anti-aliasing and the round joins that `render.py` has to fake with
/// supersampling and hand-drawn dots, so the image is made at its final size.
public enum PageImage {
    public static func png(_ raster: PageRaster) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: raster.widthPx, height: raster.heightPx,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: raster.widthPx, height: raster.heightPx))

        // Core Graphics counts y up from the bottom; paper counts it down from the top, and so does
        // every coordinate the pen reports. Without this the page is drawn upside down — which is
        // not obvious to look at, because handwriting flipped about its own line still looks like
        // handwriting. The agent that read the first page is what noticed.
        context.translateBy(x: 0, y: CGFloat(raster.heightPx))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAllowsAntialiasing(true)

        for line in raster.lines {
            let colour = cgColor(line.hex)
            context.setStrokeColor(colour)
            context.setFillColor(colour)
            let points = line.points
            guard points.count > 1 else {
                // A tap: a dot the width of the nib, not an invisible zero-length line.
                if let dot = points.first {
                    let r = dot.width / 2
                    context.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
                }
                continue
            }
            // One segment at a time, because the line widens and narrows with pressure along its
            // length and a single path can carry only one width.
            for i in 0..<(points.count - 1) {
                context.setLineWidth((points[i].width + points[i + 1].width) / 2)
                context.beginPath()
                context.move(to: CGPoint(x: points[i].x, y: points[i].y))
                context.addLine(to: CGPoint(x: points[i + 1].x, y: points[i + 1].y))
                context.strokePath()
            }
        }

        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { return nil }
        return out as Data
    }

    private static func cgColor(_ hex: String) -> CGColor {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return CGColor(red: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
