import AppKit
import OpenSmartPenCore
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

/// A use case from the folder `use-cases/` of the repository: a real handwritten page, a promise,
/// and the one sentence that a person gives their agent. The app reads the same files that the
/// repository shows, so there is one home for each.
public struct UseCase: Identifiable, Equatable {
    /// The name of its folder. It goes into telemetry, so it is never a text a person wrote.
    public let id: String
    public let title: String
    public let promise: String
    public let instruction: String
    /// What the person can change in the sentence, in one line.
    public let note: String?
    /// The sample page, as the picture file in the folder.
    public let image: Data
    /// What the person sees after the agent did its work: the name of the app, and some lines.
    public let result: Result?

    public struct Result: Decodable, Equatable {
        public let app: String
        public let items: [Item]
        public struct Item: Decodable, Equatable {
            public let text: String
            public let done: Bool?
        }
    }

    private struct Card: Decodable {
        let title, promise, instruction, image: String
        let note: String?
        let result: Result?
    }

    public static let all: [UseCase] = {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("use-case.json")),
                  let card = try? JSONDecoder().decode(Card.self, from: data),
                  let image = try? Data(contentsOf: dir.appendingPathComponent(card.image)) else { return nil }
            return UseCase(id: name, title: card.title, promise: card.promise, instruction: card.instruction, note: card.note,
                           image: image, result: card.result)
        }
    }()

    /// In the app, the folder is in the bundle. A build with no bundle, such as the design window
    /// or a test, reads it from the repository that it was built from.
    private static var folder: URL? {
        let places = [Bundle.main.resourceURL?.appendingPathComponent("use-cases"),
                      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                          .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("use-cases")]
        return places.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// The window with the use cases and the sample pages. "Add This Page" or a click on a sample page
/// files it as a photo and closes the window.
public final class SampleGalleryController: NSWindowController {
    /// `onChoose` gets the id of what was chosen and its picture.
    public init(onChoose: @escaping (String, Data) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Use Cases"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let host = NSHostingController(rootView: SampleGallery { [weak self] id, picture in
            self?.close()
            onChoose(id, picture)
        })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

private struct SampleGallery: View {
    let choose: (String, Data) -> Void
    @State private var copied: String?
    @Environment(\.colorScheme) private var scheme
    /// Drawn one time for the window, not at each redraw.
    private let drawn: [String: Data] = Dictionary(uniqueKeysWithValues: SamplePhoto.all.compactMap { sample in
        sample.png().map { (sample.id, $0) }
    })
    private static let more = URL(string: "https://github.com/opensmartpen/opensmartpen/tree/main/use-cases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(UseCase.all) { useCase($0) }
            if !SamplePhoto.all.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More sample pages").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                        ForEach(SamplePhoto.all) { sample in
                            Button { if let picture = drawn[sample.id] { choose(sample.id, picture) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    page(drawn[sample.id]).padding(.bottom, 2)
                                    Text(sample.title).font(.callout.weight(.medium))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Have a use of your own?").foregroundStyle(.secondary)
                Link("Add it on GitHub", destination: Self.more)
            }
            .font(.callout)
        }
        .padding(22)
        .frame(width: 680)
    }

    /// A use case as one card. On top, what happens: the page on paper, an arrow, and what the
    /// person finds in their app after it. Under it, the words, the sentence and the two actions.
    private func useCase(_ useCase: UseCase) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                page(useCase.image)
                    .frame(width: 310)
                    .rotationEffect(.degrees(-2))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                if let result = useCase.result {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    outcome(result)
                        .frame(width: 210)
                        .rotationEffect(.degrees(1.5))
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 7)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(LinearGradient(colors: [Ink.accent.opacity(scheme == .dark ? 0.30 : 0.16),
                                                Color.pink.opacity(scheme == .dark ? 0.16 : 0.10)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(useCase.title).font(.title2.weight(.semibold))
                    Text(useCase.promise).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    step(1, "Instruction for your agent")
                    HStack(alignment: .center, spacing: 10) {
                        Text(useCase.instruction).font(.callout.weight(.medium)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(useCase.instruction, forType: .string)
                            Telemetry.event("ui.usecase.copy", ["usecase.id": .string(useCase.id)])
                            copied = useCase.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = nil }
                        } label: {
                            Label(copied == useCase.id ? "Copied" : "Copy",
                                  systemImage: copied == useCase.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.accent.opacity(0.10)))
                    if let note = useCase.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
                VStack(alignment: .leading, spacing: 7) {
                    step(2, "Try it")
                    HStack(spacing: 10) {
                        Button { choose(useCase.id, useCase.image) } label: {
                            Label("Add This Page as a Photo", systemImage: "photo.badge.plus")
                        }
                        Text("Or write your own page with your pen.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    /// The name of a step, with its number in a small disc, as in the first panel.
    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.primary.opacity(0.12)))
            Text(title).font(.callout.weight(.medium))
        }
    }

    /// What the person finds after the agent did its work, drawn as a small list.
    private func outcome(_ result: UseCase.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.app).font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.accent)
            ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.done == true ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(item.done == true ? Ink.accent : Color.secondary)
                    Text(item.text).font(.system(size: 12.5))
                        .strikethrough(item.done == true)
                        .foregroundStyle(item.done == true ? Color.secondary : Color.primary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func page(_ data: Data?) -> some View {
        Group {
            if let data, let picture = NSImage(data: data) {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.white.aspectRatio(1200 / 760, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }
}
