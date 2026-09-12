#!/usr/bin/env swift
// Draw the app icon and write Resources/AppIcon.icns.
//
//   scripts/make-icon.swift
//
// The glyph is the notebook from the panel's own book rows — `PaperMark`, bound, with the ink dot
// on its corner. Kept here as code rather than as a checked-in image so the two cannot drift apart
// silently: redraw the mark and this is the one file to match.
//
// A notebook rather than a pencil, because a pencil is what every note app puts on its icon and
// says nothing about this one. The elastic band is the part that reads as *this* notebook even at
// 16 px, and the dot is the single point of colour the panel allows itself.
import AppKit

let side: CGFloat = 1024
// Big Sur proportions: the rounded square sits inside the 1024 canvas with a margin, and its
// corner radius is a shade under a quarter of its width.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
// Ink.accent, light appearance, from StatusPanel.
let accent = NSColor(srgbRed: 0.357, green: 0.247, blue: 0.769, alpha: 1)
let plateTop = NSColor(calibratedRed: 0.98, green: 0.976, blue: 0.969, alpha: 1)
let plateBottom = NSColor(calibratedRed: 0.902, green: 0.890, blue: 0.875, alpha: 1)

func drawIcon(into size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = size / side   // everything below is authored at 1024 and scaled down

    let plateRect = NSRect(x: plate.minX * k, y: plate.minY * k,
                           width: plate.width * k, height: plate.height * k)
    let shape = NSBezierPath(roundedRect: plateRect,
                             xRadius: cornerRadius * k, yRadius: cornerRadius * k)
    NSGradient(starting: plateTop, ending: plateBottom)?.draw(in: shape, angle: -90)

    // PaperMark's shape, not its stroke weight. Its 1-in-11 line is right at 13 px and turns
    // clumsy blown up to 1024, where the same ratio reads as a fat letter rather than a notebook,
    // so the glyph is drawn larger and lighter while the proportions it is recognised by — the
    // page ratio, the elastic at 0.72 of the width — are kept exactly.
    let h = plate.height * 0.56 * k
    let w = h * (8.5 / 11.0)
    let book = NSRect(x: plateRect.midX - w / 2, y: plateRect.midY - h / 2, width: w, height: h)
    let stroke = h / 17
    ink.setStroke()
    let outline = NSBezierPath(roundedRect: book, xRadius: h * 0.085, yRadius: h * 0.085)
    outline.lineWidth = stroke
    outline.stroke()

    // The elastic, nearer the spine than the middle, running just off both edges as it does on the
    // real thing — the one detail that still says "notebook" at 16 px.
    let bandX = book.minX + w * 0.72
    let band = NSBezierPath()
    band.move(to: NSPoint(x: bandX, y: book.minY - stroke * 1.1))
    band.line(to: NSPoint(x: bandX, y: book.maxY + stroke * 1.1))
    band.lineWidth = stroke
    band.lineCapStyle = .round
    band.stroke()

    // The ink dot on the top corner, as in the panel, where it marks the book being written in.
    // Here it is simply the one thing carrying colour — and at 16 px it is the only thing that
    // still does, which is why it is worth keeping.
    let d = w * 0.30
    let dot = NSRect(x: book.maxX - d * 0.5, y: book.maxY - d * 0.5, width: d, height: d)
    accent.setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build-icon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Each size is redrawn rather than downsampled from one big bitmap: the glyph is an outline, and
// a 1.35-unit stroke resampled down to 16 px turns to mush.
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = drawIcon(into: CGFloat(px))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
print("wrote \(out.path)")
