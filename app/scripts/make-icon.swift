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

    // The ink dot, centred on the cover's top right corner so it straddles it evenly.
    //
    // Not the panel's own offset. There the dot is a badge hung off a 15-point row-mark, clear of
    // the glyph so it cannot be mistaken for part of the book; at icon size that same offset reads
    // as a dot floating loose in the plate. The corner is what the eye goes to, so the dot sits on
    // it — the one place it belongs to the notebook rather than to the empty square around it.
    let d = 4.4 * u
    // A shade outward along both axes: dead-centre on the corner, the dot eats the head of the
    // elastic and the whole thing reads as a pin stuck in a page.
    let corner = NSPoint(x: book.maxX + 0.6 * u, y: book.maxY + 0.6 * u)
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: corner.x - d / 2, y: corner.y - d / 2,
                                width: d, height: d)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build-icon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Each size is redrawn rather than downsampled from one big bitmap: the glyph is an outline, and
// a hairline stroke resampled down to 16 px turns to mush.
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

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

func run(_ tool: String, _ args: [String]) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = args
    let quiet = Pipe()
    task.standardOutput = quiet
    task.standardError = quiet
    try task.run()
    _ = quiet.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return task.terminationStatus
}

// 1. Assets.car, which is a different thing from the .icns and the reason this script grew.
//
// Notification Center does not read CFBundleIconFile. It resolves an app's icon through
// CFBundleIconName and the compiled asset catalog, so an .icns-only bundle shows a blank grey
// square on every banner while Finder shows the icon perfectly. Both forms have to ship: the
// catalog for notifications, the .icns for everything that still expects one.
let catalog = root.appendingPathComponent("build-icon.xcassets")
let appiconset = catalog.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: catalog)
try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)
try Data(#"{"info":{"version":1,"author":"make-icon.swift"}}"#.utf8)
    .write(to: catalog.appendingPathComponent("Contents.json"))

// macOS icons are declared as a point size plus a scale; the files are already both.
var images: [String] = []
for (pt, scale, px) in [(16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64),
                        (128, 1, 128), (128, 2, 256), (256, 1, 256), (256, 2, 512),
                        (512, 1, 512), (512, 2, 1024)] {
    let name = "icon_\(px).png"
    let file = appiconset.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: file.path) {
        try drawIcon(into: CGFloat(px)).representation(using: .png, properties: [:])!.write(to: file)
    }
    images.append(#"{"idiom":"mac","size":"\#(pt)x\#(pt)","scale":"\#(scale)x","filename":"\#(name)"}"#)
}
try Data(#"{"images":[\#(images.joined(separator: ","))],"info":{"version":1}}"#.utf8)
    .write(to: appiconset.appendingPathComponent("Contents.json"))

// Compiled somewhere of its own, then only Assets.car is taken. actool also emits an AppIcon.icns
// carrying just the handful of sizes it thinks are needed, and pointed straight at Resources it
// drops that on top of the ten-size one below — which is how this arrived with a 256-pixel icon
// and no explanation.
let staging = root.appendingPathComponent("build-icon-out")
try? FileManager.default.removeItem(at: staging)
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
let partial = root.appendingPathComponent("build-icon-plist.plist")
let actool = try run("/usr/bin/xcrun", ["actool", catalog.path,
    "--compile", staging.path,
    "--app-icon", "AppIcon",
    "--output-partial-info-plist", partial.path,
    "--platform", "macosx", "--minimum-deployment-target", "13.0"])

let car = staging.appendingPathComponent("Assets.car")
guard actool == 0, FileManager.default.fileExists(atPath: car.path) else {
    FileHandle.standardError.write("actool did not produce Assets.car\n".data(using: .utf8)!)
    exit(1)
}
let carOut = resources.appendingPathComponent("Assets.car")
try? FileManager.default.removeItem(at: carOut)
try FileManager.default.copyItem(at: car, to: carOut)

// 2. The .icns, written last so nothing can overwrite it. Finder, the Dock and Get Info read this.
let icns = resources.appendingPathComponent("AppIcon.icns")
guard try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]) == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.removeItem(at: catalog)
try? FileManager.default.removeItem(at: staging)
try? FileManager.default.removeItem(at: partial)

print("wrote \(icns.path) and Assets.car")
