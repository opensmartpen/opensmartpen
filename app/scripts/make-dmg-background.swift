#!/usr/bin/env swift
// Draw the picture behind the icons in the window of the disk image.
//
//   scripts/make-dmg-background.swift <file.png>
//
// The window shows two icons: the app on the left and the Applications folder on the right. The
// picture puts an arrow between them and says, in one line, what to do. It also says the second
// way, because the app moves itself when it is opened from the image.
//
// 600 by 400 points, drawn at twice that, so it is sharp on every screen. The places of the two
// icons are in scripts/make-dmg.sh; the arrow here is drawn between the same two places.
import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <file.png>\n".utf8))
    exit(2)
}
let width = 600.0, height = 400.0, scale = 2.0
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
rep.size = NSSize(width: width, height: height)   // so the Finder shows it at 600 by 400 points
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: scale, y: scale)

// The plate of the logo, lighter: lilac at the top right, pink at the bottom left, on near-white.
NSColor(srgbRed: 0.975, green: 0.970, blue: 0.990, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
NSGradient(colors: [NSColor(srgbRed: 0.80, green: 0.76, blue: 0.98, alpha: 0.55), NSColor(srgbRed: 0.80, green: 0.76, blue: 0.98, alpha: 0)])?
    .draw(fromCenter: NSPoint(x: width, y: height), radius: 0, toCenter: NSPoint(x: width, y: height), radius: 420, options: [])
NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.80, blue: 0.90, alpha: 0.45), NSColor(srgbRed: 0.99, green: 0.80, blue: 0.90, alpha: 0)])?
    .draw(fromCenter: NSPoint(x: 0, y: 0), radius: 0, toCenter: NSPoint(x: 0, y: 0), radius: 380, options: [])

// The arrow, between the two icons. The Finder counts down from the top; this counts up.
let ink = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.23, alpha: 0.75)
let y = height - 215.0
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 245, y: y))
arrow.line(to: NSPoint(x: 355, y: y))
arrow.move(to: NSPoint(x: 339, y: y + 13))
arrow.line(to: NSPoint(x: 355, y: y))
arrow.line(to: NSPoint(x: 339, y: y - 13))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
ink.setStroke()
arrow.stroke()

func centred(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.23, alpha: alpha),
    ])
    string.draw(at: NSPoint(x: (width - string.size().width) / 2, y: y))
}
// The words are above the icons, not under them. A Finder window can be shorter than this
// picture, for example when the disk opens as a tab of a window that is open already, and then
// what is at the bottom is cut off. What is at the top is always seen.
centred("Drag Open Smart Pen to Applications", size: 16, weight: .semibold, alpha: 0.92, y: height - 62)
centred("Or double-click it here, and it moves itself.", size: 12.5, weight: .regular, alpha: 0.62, y: height - 86)

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
