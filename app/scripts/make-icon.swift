#!/usr/bin/env swift
// Draw the app icon and write Resources/AppIcon.icns.
//
//   scripts/make-icon.swift
//
// The glyph is the menubar pencil: the same path, on the same 16-unit grid, as `StatusIcon.pencil`.
// Kept here as code rather than as a checked-in image so the two cannot drift apart silently:
// redraw one and this is the file to match.
//
// It carries no ink drop. In the menubar the drop means pages are waiting to sync, and an icon
// has no business claiming a state.
//
//   scripts/make-icon.swift --logo <file.png>     also writes the 512-pixel picture the README shows
//   scripts/make-icon.swift --avatar <file.png>   also writes it with the plate filling the square
import AppKit

let side: CGFloat = 1024
// Big Sur proportions: the rounded square sits inside the 1024 canvas with a margin, and its
// corner radius is a shade under a quarter of its width.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

// Pure black, in every picture.
let ink = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
let avatarViolet = NSColor(srgbRed: 0.545, green: 0.424, blue: 1, alpha: 1)
let avatarPink = NSColor(srgbRed: 1, green: 0.722, blue: 0.851, alpha: 1)
let plateTop = NSColor(calibratedRed: 0.98, green: 0.976, blue: 0.969, alpha: 1)
let plateBottom = NSColor(calibratedRed: 0.902, green: 0.890, blue: 0.875, alpha: 1)

/// `fullBleed` fills the whole square with the plate, with no margin and no rounded corners. That
/// is the picture for a place that crops and frames it itself, such as a GitHub profile: the app
/// icon's own margin shows there as a tile inside a tile.
///
/// `gentle` is the one look of every picture that is made here: the tinted plate and the bigger
/// pencil. The app icon, the logo in `assets/` and the profile picture all have it, so a person
/// sees one mark in the Dock of the settings window, in the README and on GitHub. The plain plate
/// is still drawn when `gentle` is false; nothing asks for it now.
func drawIcon(into size: CGFloat, fullBleed: Bool = false, gentle: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = size / side   // everything below is authored at 1024 and scaled down

    let plateRect = fullBleed
        ? NSRect(x: 0, y: 0, width: size, height: size)
        : NSRect(x: plate.minX * k, y: plate.minY * k, width: plate.width * k, height: plate.height * k)
    let shape = fullBleed
        ? NSBezierPath(rect: plateRect)
        : NSBezierPath(roundedRect: plateRect, xRadius: cornerRadius * k, yRadius: cornerRadius * k)
    if gentle {
        // A profile picture is seen at 20 to 40 pixels, on a dark page and on a white one. The
        // plate is near-white with a violet tint from the top right and a pink one from the
        // bottom left: gentle, and still a shape of its own on a white page.
        NSColor(srgbRed: 0.984, green: 0.980, blue: 1, alpha: 1).setFill()
        shape.fill()
        // The tints stay inside the plate, whatever its shape.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let w = plateRect.width
        for (tint, at, reach) in [(avatarViolet, NSPoint(x: plateRect.maxX, y: plateRect.maxY), w * 1.0),
                                  (avatarPink, NSPoint(x: plateRect.minX, y: plateRect.minY), w * 0.9)] {
            NSGradient(starting: tint.withAlphaComponent(0.5), ending: tint.withAlphaComponent(0))?
                .draw(fromCenter: at, radius: 0, toCenter: at, radius: reach, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()
    } else {
        NSGradient(starting: plateTop, ending: plateBottom)?.draw(in: shape, angle: -90)
    }

    // The pencil from StatusIcon, on its own 16-unit grid, blown up to fill the plate.
    //
    // One number is not the menubar's: the 1.35 stroke. It is right at 17 points and reads as a
    // marker at 1024, so it is thinned to 1.0. The shape is what has to match.
    // The profile picture has a bigger pencil with the menubar's own stroke: both were made for
    // small sizes.
    let grid = plateRect.height * (gentle ? 0.76 : 0.60)
    let weight: CGFloat = gentle ? 1.35 : 1.0
    let u = grid / 16
    let ox = plateRect.midX - grid / 2
    let oy = plateRect.midY - grid / 2
    // The design is authored downward, AppKit draws upward.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + (16 - y) * u) }

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

    // The band ends on the outline, so its ends are cut square: a round end would show as a bump
    // outside the pencil at this size.
    ink.setStroke()
    for path in [body, ferrule] {
        path.lineWidth = weight * u
        path.lineCapStyle = path === ferrule ? .butt : .round
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
// a hairline stroke resampled down to 16 px turns to mush.
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = drawIcon(into: CGFloat(px), gentle: true)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

// The picture for the README and for GitHub, only when asked for: it is the one icon file that is
// committed, because a web page cannot run this script.
if let flag = CommandLine.arguments.firstIndex(of: "--logo"), CommandLine.arguments.count > flag + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    try drawIcon(into: 512, gentle: true).representation(using: .png, properties: [:])!.write(to: out)
}
// The same mark filling the whole square, for a profile picture.
if let flag = CommandLine.arguments.firstIndex(of: "--avatar"), CommandLine.arguments.count > flag + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    try drawIcon(into: 512, fullBleed: true, gentle: true).representation(using: .png, properties: [:])!.write(to: out)
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
        try drawIcon(into: CGFloat(px), gentle: true).representation(using: .png, properties: [:])!.write(to: file)
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
