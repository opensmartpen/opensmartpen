#!/usr/bin/env swift
// Draw the app icon and write Resources/AppIcon.icns.
//
//   scripts/make-icon.swift
//
// The glyph is the menubar pencil: the same path, on the same 16-unit grid, copied from
// StatusIcon.pencil. Keeping it here as code rather than as a checked-in image means the two
// cannot drift apart silently — if the pencil is redrawn, this is one file to match.
//
// The resting pencil, with no ink drop: the drop means pages are waiting to sync, which is a state
// an app icon has no business claiming. Same reason the icon carries no colour — in this app
// colour only appears when it means something.
import AppKit

let side: CGFloat = 1024
// Big Sur proportions: the rounded square sits inside the 1024 canvas with a margin, and its
// corner radius is a shade under a quarter of its width.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
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

    // The 16-unit grid the menubar pencil is drawn on, centred and scaled to fill the plate.
    let grid: CGFloat = 16
    let glyph = plate.width * 0.60 * k
    let scale = glyph / grid
    let ox = plateRect.midX - glyph / 2
    let oy = plateRect.midY - glyph / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: ox + x * scale, y: oy + (grid - y) * scale)
    }

    let body = NSBezierPath()
    body.move(to: p(11.2, 1.6))
    body.line(to: p(14.4, 4.8))
    body.line(to: p(5.6, 13.6))
    body.line(to: p(1.9, 14.5))
    body.line(to: p(2.8, 10.8))
    body.close()

    let ferrule = NSBezierPath()
    ferrule.move(to: p(9.6, 3.2))
    ferrule.line(to: p(12.8, 6.4))

    ink.setStroke()
    for path in [body, ferrule] {
        path.lineWidth = 1.35 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

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
