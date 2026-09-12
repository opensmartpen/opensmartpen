import Foundation

/// What a pen was last seen doing: its battery, and when.
///
/// Kept beside the app's config rather than in the notes repo, unlike `pens/<slug>.json`. The
/// dividing line is whether the processing side needs it: a pen's name, mode and default ink
/// decide how a stroke is rendered, so they belong in the repo. A battery reading decides nothing
/// downstream, changes every few minutes, and committing one to git on every change would be
/// noise in a history meant to hold handwriting.
public struct PenReading: Codable, Equatable {
    public var battery: Int
    public var charging: Bool
    /// When this reading was taken, which is also the last time the pen was in range.
    public var at: Date

    public init(battery: Int, charging: Bool, at: Date) {
        self.battery = battery
        self.charging = charging
        self.at = at
    }
}

/// Last-known readings for every pen this Mac has met, keyed by MAC.
///
/// The point of remembering them is the menubar: with more than one pen, the one you are holding
/// is not necessarily the one that needs charging, and a pen that is flat in a drawer is exactly
/// the one you will reach for tomorrow and find dead.
public final class PenState {
    public static let fileName = "pen-state.json"

    private let url: URL
    private var readings: [String: PenReading]

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
        // Read with the same date strategy it is written with. Mismatched strategies fail
        // silently — the file is there, every reading is dropped, and the app simply forgets
        // which pen was flat.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        readings = (try? decoder.decode([String: PenReading].self,
                                        from: Data(contentsOf: url))) ?? [:]
    }

    public func reading(mac: String) -> PenReading? { readings[PenRecord.normalise(mac)] }

    public var all: [String: PenReading] { readings }

    public func record(mac: String, battery: Int, charging: Bool, at: Date = Date()) {
        let key = PenRecord.normalise(mac)
        let reading = PenReading(battery: battery, charging: charging, at: at)
        guard readings[key] != reading else { return }
        readings[key] = reading
        save()
    }

    /// A pen used within `window` and at or below `threshold`, worst first. Charging pens are not
    /// a problem and a pen nobody has touched for a week is not urgent — you would find it flat
    /// and charge it, which is different from being surprised by it mid-sentence.
    public func lowBatteries(threshold: Int, window: TimeInterval = 24 * 3600,
                             now: Date = Date()) -> [(mac: String, reading: PenReading)] {
        readings
            .filter { !$0.value.charging
                && $0.value.battery <= threshold
                && now.timeIntervalSince($0.value.at) <= window }
            .sorted { $0.value.battery < $1.value.battery }
            .map { (mac: $0.key, reading: $0.value) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(readings).write(to: url, options: .atomic)
        } catch {
            Log.error("writing \(Self.fileName) failed: \(error)")
        }
    }
}
