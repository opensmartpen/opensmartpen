import AppKit
import SwiftUI

/// A page that the app brings itself, for a person with no pen and no photo at hand who wants to
/// see an agent read something. Each one is a use of the app: a list, the notes of a meeting, the
/// notes of a lesson, a plan from a whiteboard.
///
/// A stand-in. Each page is drawn from a font, so it is easier to read than real handwriting and
/// proves less. A real sample is a page written with a pen, kept as its strokes and drawn like
/// every other page.
public struct SamplePhoto: Identifiable, Equatable {
    /// One fixed word. It goes into telemetry, so it is never a text that a person wrote.
    public let id: String
    public let title: String
    /// What a person can ask their agent to do with a page like this one.
    public let hint: String
    let lines: [Line]

    enum Line: Equatable {
        case heading(String)
        case box(done: Bool, String)
        case dash(String)
        /// What follows from the page, in red.
        case arrow(String)
    }

    public static let all: [SamplePhoto] = [
        SamplePhoto(id: "todo", title: "To-do list", hint: "Ask your agent to add the open tasks to your list.",
                    lines: [.heading("TODO"), .box(done: false, "Buy milk"), .box(done: false, "Call mom"),
                            .box(done: true, "Teach the pen to read"),
                            .box(done: false, "Take over the world (after lunch)")]),
        SamplePhoto(id: "meeting", title: "Meeting notes", hint: "Ask your agent to send the notes to the team.",
                    lines: [.heading("Product review"), .dash("pricing page: per seat?"),
                            .dash("ask legal about the terms"), .dash("who owns the film?"),
                            .arrow("send notes to everyone")]),
        SamplePhoto(id: "study", title: "Study notes", hint: "Ask your agent to test you on it.",
                    lines: [.heading("Photosynthesis"), .dash("light \u{2192} ATP + NADPH"),
                            .dash("Calvin cycle: CO\u{2082} \u{2192} sugar"), .dash("happens in the chloroplast"),
                            .arrow("why are leaves green?")]),
        SamplePhoto(id: "plan", title: "Whiteboard plan", hint: "Ask your agent to make a document from it.",
                    lines: [.heading("Q1 plan"), .dash("launch in March"), .dash("ten test users"),
                            .dash("write the docs"), .arrow("budget by Friday")]),
    ]

    /// The picture of the page, as a PNG.
    public func png() -> Data? {
        let width = 1200, height = 760
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let red = NSColor(calibratedRed: 0.78, green: 0.1, blue: 0.2, alpha: 1)

        func font(_ size: CGFloat) -> NSFont {
            NSFont(name: "BradleyHandITCTT-Bold", size: size) ?? NSFont(name: "Noteworthy-Bold", size: size)
                ?? .systemFont(ofSize: size)
        }
        func draw(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor = .black) {
            NSAttributedString(string: text, attributes: [.font: font(size), .foregroundColor: color])
                .draw(at: point)
        }

        // AppKit counts y up from the bottom, so the first line is the highest.
        var y = CGFloat(height) - 150
        for line in lines {
            switch line {
            case let .heading(text):
                draw(text, at: NSPoint(x: 90, y: y), size: 84)
                y -= 120
                continue
            case let .box(done, text):
                NSColor.black.setStroke()
                let box = NSBezierPath(rect: NSRect(x: 96, y: y + 14, width: 44, height: 44))
                box.lineWidth = 4
                box.stroke()
                if done {
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: 102, y: y + 38))
                    tick.line(to: NSPoint(x: 116, y: y + 20))
                    tick.line(to: NSPoint(x: 150, y: y + 70))
                    tick.lineWidth = 6
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    tick.stroke()
                }
                draw(text, at: NSPoint(x: 172, y: y), size: 58)
            case let .dash(text):
                draw("\u{2013}", at: NSPoint(x: 100, y: y), size: 58)
                draw(text, at: NSPoint(x: 172, y: y), size: 58)
            case let .arrow(text):
                draw("\u{2192}", at: NSPoint(x: 96, y: y), size: 58, color: red)
                draw(text, at: NSPoint(x: 172, y: y), size: 58, color: red)
            }
            y -= 110
        }
        return rep.representation(using: .png, properties: [:])
    }
}

/// The window with the sample pages. A click on one adds it as a photo and closes the window.
public final class SampleGalleryController: NSWindowController {
    public init(onChoose: @escaping (SamplePhoto) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sample Photos"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let host = NSHostingController(rootView: SampleGallery { [weak self] sample in
            self?.close()
            onChoose(sample)
        })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

private struct SampleGallery: View {
    let choose: (SamplePhoto) -> Void
    /// Drawn one time for the window, not at each redraw.
    private let pictures: [String: NSImage] = Dictionary(uniqueKeysWithValues: SamplePhoto.all.compactMap { sample in
        sample.png().flatMap(NSImage.init(data:)).map { (sample.id, $0) }
    })

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a sample page to try the app. Your agent reads it like a page from your pen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 18) {
                ForEach(SamplePhoto.all) { sample in
                    Button { choose(sample) } label: { card(sample) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func card(_ sample: SamplePhoto) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let picture = pictures[sample.id] {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.white.aspectRatio(1200 / 760, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            .padding(.bottom, 4)
            Text(sample.title).font(.headline)
            Text(sample.hint).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}
