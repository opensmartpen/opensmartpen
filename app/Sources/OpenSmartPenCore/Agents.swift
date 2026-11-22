import Foundation

/// One agent, as it describes itself in `agents/<n>.json`.
///
/// The app cannot see an agent. What it can see is a small file the agent keeps: its name, when
/// it was last alive, and an address to open, if it has one. An agent takes the first free
/// number, and writes the time again at each of its checks.
public struct AgentRecord: Equatable {
    public let number: Int
    public var name: String
    /// When the agent last looked at the pages.
    public var alive: Date
    /// Somewhere a person can go to see the agent. Only a web address is ever opened.
    public var url: URL?

    public init(number: Int, name: String, alive: Date, url: URL? = nil) {
        self.number = number
        self.name = name
        self.alive = alive
        self.url = url
    }

    /// Nil for a file that is not an agent's record, so a stray file cannot show as an agent.
    public init?(number: Int, json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty,
              let text = obj["alive"] as? String, let alive = Agents.date(text) else { return nil }
        let url = (obj["url"] as? String).flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        self.init(number: number, name: String(name.prefix(60)), alive: alive, url: url)
    }

    /// An agent is behind when pages changed after it was last alive, and it has had two hours
    /// to notice. An agent with nothing to do is never behind, however long it has been silent:
    /// it should not have to spend anything to say it is still there.
    public func isBehind(changed: Date?, now: Date = Date()) -> Bool {
        guard let changed, alive < changed else { return false }
        return now.timeIntervalSince(changed) > Agents.patience
    }
}

/// The agents that work with the pages, and what a person gives a new one.
public enum Agents {
    /// How long an agent may leave a change unseen before it is shown as behind.
    public static let patience: TimeInterval = 2 * 60 * 60
    /// The most agents ever asked for. The app asks by name.
    public static let limit = 16

    public static func path(_ number: Int) -> String { "agents/\(number).json" }

    /// Where an agent starts: the website's page for agents, which leads to the setup text.
    public static let setupURL = "https://opensmartpen.org/llms.txt"

    /// What a person gives their agent. One sentence to start, and where the pages are.
    public static func sentence(folder: URL, bucket: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path.hasPrefix(home) ? "~" + folder.path.dropFirst(home.count) : folder.path
        var text = "Read \(setupURL) and set yourself up to transcribe my Open Smart Pen pages. "
        text += "The pages are in the folder \(path) on my Mac"
        if let bucket { text += ", and in the bucket \(bucket)" }
        return text + "."
    }

    /// The agents recorded in the folder on this Mac, in order. A number with no file is passed
    /// over: a person can remove an agent, and the ones after it stay.
    public static func load(root: URL) -> [AgentRecord] {
        (0..<limit).compactMap { number in
            (try? Data(contentsOf: root.appendingPathComponent(path(number))))
                .flatMap { AgentRecord(number: number, json: $0) }
        }
    }

    /// Ask the bucket for each agent's record, by name, and keep what it has in the folder.
    /// Nothing is listed, so the key needs no more than it has. It asks for each number the
    /// folder knows, and then on to the first one that is not there.
    public static func fetch(root: URL, client: S3Client) {
        let known = load(root: root).map(\.number).max() ?? -1
        for number in 0..<limit {
            guard let data = try? client.get(path(number)) else {
                if number > known { break }
                continue
            }
            let url = root.appendingPathComponent(path(number))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Remove one agent's record, from the bucket and from the folder. The agent is not stopped:
    /// the app cannot reach it. One that still runs writes its record again at its next check.
    public static func remove(_ number: Int, root: URL, client: S3Client?) throws {
        try client?.delete(path(number))
        let url = root.appendingPathComponent(path(number))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// When a page picture last changed, as `last-modified.txt` has it.
    public static func lastChange(root: URL) -> Date? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(PagePictures.timePath), encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("changed:") {
            return date(line.dropFirst("changed:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// ISO 8601, with or without fractions of a second: agents write either.
    static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}
