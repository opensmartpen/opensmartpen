import Foundation

/// What a pen is for. Chosen by picking up a pen rather than by tapping a mode onto the one pen
/// you own, which is the point: a pen in your hand is self-evident, and a mode is invisible once
/// set. The renderer reads this; Brainio Pen only stores it.
///
/// Two, not three. There was an `accent` between them, and it said nothing an ink colour does not
/// already say. A record that still says `accent` is read as `writing`.
public enum PenMode: String, CaseIterable, Codable {
    case writing, highlight
}

/// A pen as the notes repo records it, in `pens/<slug>.json`.
///
/// The same shape of problem as a notebook, solved the same way and in the same place: a hardware
/// identifier that must never change, and a name that must be free to. It lives in the repo rather
/// than in the app's config because the *renderer* is what needs to know that a pen means
/// "highlighter" — every stroke already carries `"pen":"<mac>"`, so the role is a lookup on the
/// derived side and raw stays honest about which physical pen made the mark.
public struct PenRecord: Equatable {
    public let slug: String
    /// Bluetooth MAC, lowercase and unpunctuated. Matches `Stroke.penMac`.
    public let mac: String
    public var name: String
    public var mode: PenMode
    /// What this pen writes with when nothing has been chosen, and what writing returns to after
    /// a long enough silence. The paper controller overrides it for as long as you are writing.
    public var ink: InkColor
    public var width: LineWidth

    public init(slug: String, mac: String, name: String, mode: PenMode = .writing,
                ink: InkColor = .black, width: LineWidth = .default) {
        self.slug = slug
        self.mac = mac
        self.name = name
        self.mode = mode
        self.ink = ink
        self.width = width
    }

    private struct Payload: Codable {
        var mac: String
        var name: String?
        var mode: String?
        var ink: String?
        var width: String?
    }

    /// Nil for a file that is not a pen record, so a stray JSON file cannot break the panel.
    public init?(slug: String, json: Data) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        self.init(slug: slug,
                  mac: PenRecord.normalise(p.mac),
                  name: p.name ?? slug,
                  mode: p.mode.flatMap(PenMode.init(rawValue:)) ?? .writing,
                  ink: p.ink.flatMap(InkColor.init(rawValue:)) ?? .black,
                  width: p.width.flatMap(LineWidth.init(rawValue:)) ?? .default)
    }

    public var json: Data {
        let payload = Payload(mac: mac, name: name, mode: mode.rawValue,
                              ink: ink.rawValue, width: width.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// MACs arrive punctuated in some places and bare in others; compare them one way only.
    public static func normalise(_ mac: String) -> String {
        mac.lowercased().filter { $0.isHexDigit }
    }

    /// A filename from a name the person typed. Set once, when the record is created.
    public static func slug(from name: String, mac: String) -> String {
        let cleaned = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, c in
                if c == "-" && (out.isEmpty || out.hasSuffix("-")) { return }
                out.append(c)
            }
        let trimmed = cleaned.hasSuffix("-") ? String(cleaned.dropLast()) : cleaned
        return trimmed.isEmpty ? "pen-\(normalise(mac).suffix(4))" : trimmed
    }
}

/// Every pen the repo knows, keyed by MAC. Reloaded when `pens/` changes, so renaming a pen shows
/// up without restarting Brainio Pen — the same contract as `BookRegistry`.
public final class PenRegistry {
    private let repo: URL
    private var byMac: [String: PenRecord] = [:]
    private var loadedStamp: DirectoryStamp?

    public init(repo: URL) {
        self.repo = repo
        reloadIfNeeded()
    }

    public var pens: [PenRecord] {
        reloadIfNeeded()
        return byMac.values.sorted { $0.name < $1.name }
    }

    public func record(mac: String) -> PenRecord? {
        reloadIfNeeded()
        return byMac[PenRecord.normalise(mac)]
    }

    /// The name to show for a pen, falling back to something a person would say rather than to a
    /// MAC address — which is exactly the kind of hardware identifier the interface is not allowed
    /// to leak.
    public func name(mac: String) -> String {
        record(mac: mac)?.name ?? "Pen"
    }

    /// What this pen writes with when nothing has been chosen. Used by the panel and by the
    /// renderer's reset rule, which returns here after a long silence.
    public func defaults(mac: String) -> (ink: InkColor, width: LineWidth) {
        guard let r = record(mac: mac) else { return (.black, .default) }
        return (r.ink, r.width)
    }

    /// Create a record for a pen we have not seen before. The slug is fixed here and never again:
    /// it is the filename, and a filename that follows a display name is a rename that moves data.
    @discardableResult
    public func create(mac: String, name: String) -> PenRecord? {
        let mac = PenRecord.normalise(mac)
        if let existing = record(mac: mac) { return existing }
        let record = PenRecord(slug: PenRecord.slug(from: name, mac: mac), mac: mac, name: name)
        return save(record) ? record : nil
    }

    /// Write a record back. Everything except the slug and the MAC is free to change.
    @discardableResult
    public func save(_ record: PenRecord) -> Bool {
        let dir = repo.appendingPathComponent("pens")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try record.json.write(to: dir.appendingPathComponent("\(record.slug).json"), options: .atomic)
            loadedStamp = nil          // force a reload rather than guess at the new stamp
            reloadIfNeeded()
            return true
        } catch {
            Log.error("writing pens/\(record.slug).json failed: \(error)")
            return false
        }
    }

    private func reloadIfNeeded() {
        let dir = repo.appendingPathComponent("pens")
        let stamp = DirectoryStamp(of: dir)
        if let loadedStamp, stamp == loadedStamp { return }
        loadedStamp = stamp

        byMac = [:]
        for file in stamp.files {
            guard let data = try? Data(contentsOf: file),
                  let record = PenRecord(slug: file.deletingPathExtension().lastPathComponent,
                                         json: data) else { continue }
            byMac[record.mac] = record
        }
    }
}

/// A cheap "has anything in this directory changed" reading, stamped from the files themselves.
/// The directory's own timestamp does not move when a file inside it is edited in place, so
/// watching that would miss exactly the change we care about — a rename.
struct DirectoryStamp: Equatable {
    let files: [URL]
    let count: Int
    let newest: Date

    init(of directory: URL) {
        let found = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
        files = found
        count = found.count
        newest = found.reduce(Date.distantPast) { newest, file in
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return max(newest, modified)
        }
    }

    static func == (a: DirectoryStamp, b: DirectoryStamp) -> Bool {
        a.count == b.count && a.newest == b.newest && a.files == b.files
    }
}
