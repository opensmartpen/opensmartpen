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

    // The bound mark from PaperMark, which is itself traced from the panel design: rect at
    // (2.5, 2) sized 10 x 12 with a 1.6 corner, and the elastic down x = 10.6, all on the same
    // 16-unit grid. The grid is blown up to fill the plate instead of the panel's 15 points.
    //
    // One number is deliberately not the design's: the 1.1 stroke. It is right at 15 pt and reads
    // as a fat letter at 1024, so it is thinned to 0.75 — the shape is what has to match, and a
    // line weight copied across a 70x scale change matches the drawing but not the drawing's
    // intent. Everything else is exact, so the two can be checked against each other.
    let grid = plate.height * 0.62 * k
    let u = grid / 16
    let ox = plateRect.midX - grid / 2
    let oy = plateRect.midY - grid / 2
    // The design is authored downward, AppKit draws upward.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + (16 - y) * u) }

    let book = NSRect(x: ox + 2.5 * u, y: oy + 2 * u, width: 10 * u, height: 12 * u)
    ink.setStroke()
    let outline = NSBezierPath(roundedRect: book, xRadius: 1.6 * u, yRadius: 1.6 * u)
    outline.lineWidth = 0.75 * u
    outline.stroke()

    let elastic = NSBezierPath()
    elastic.move(to: p(10.6, 2))
    elastic.line(to: p(10.6, 14))
    elastic.lineWidth = 0.75 * u
    elastic.stroke()

    // The ink dot, exactly where the panel puts it on the book being written in: 5 px across,
    // top:-1 and right:-3 against a 15-point mark. The design measures that mark in CSS pixels
    // while the glyph inside it is a 16-unit viewBox, so every one of those numbers is 16/15 of a
    // unit — the conversion that has to happen once, here, or the dot floats off the corner.
    let s = 16.0 / 15.0
    let d = 5 * s * u
    let dot = NSRect(x: ox + (18 * s - 5 * s) * u,        // right edge at 15 + 3, less its width
                     y: oy + (16 - (-1 * s + 5 * s)) * u, // top at -1, flipped for AppKit
                     width: d, height: d)
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
