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
    /// The most agents ever asked for. The app asks by name and stops at the first gap.
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

    /// Claude Desktop, by the name macOS knows it under.
    public static let claudeDesktop = "com.anthropic.claudefordesktop"

    /// A link that opens Claude Desktop on a new Cowork task with the notes folder, and the
    /// sentence already typed. Nothing is sent: the person reads it and presses Return. Claude asks
    /// once whether another app may give it the folder.
    ///
    /// Cowork is where a person who is not a programmer works with Claude and with folders. Its
    /// cost is speed: it wakes on its own schedule, hourly at the shortest.
    ///
    /// The form `claude://cowork/new?q=…&folder=…` was read out of Claude Desktop 5.11 and tried
    /// on 2026-11-17.
    public static func coworkLink(folder: URL, bucket: String?) -> URL? {
        var parts = URLComponents()
        parts.scheme = "claude"
        parts.host = "cowork"
        parts.path = "/new"
        parts.queryItems = [URLQueryItem(name: "q", value: sentence(folder: folder, bucket: bucket)),
                            URLQueryItem(name: "folder", value: folder.path)]
        return parts.url
    }

    /// A script for the Terminal that starts Claude Code in the notes folder with the sentence.
    /// Claude Code can run commands, so it can set up a check that costs nothing while no page
    /// changes and runs each minute: the fast way. The prompt is sent as the session starts;
    /// Claude Code still asks before it does anything.
    public static func terminalScript(folder: URL, bucket: String?, claude: URL) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/zsh
        cd \(quoted(folder.path)) || exit 1
        exec \(quoted(claude.path)) \(quoted(sentence(folder: folder, bucket: bucket)))

        """
    }

    /// Where the `claude` command is, among the places its installers put it. An app started by
    /// macOS does not have the person's shell path, so the places are named.
    public static func claudeCommand(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let places = [home.appendingPathComponent(".local/bin/claude"),
                      home.appendingPathComponent(".claude/local/claude"),
                      URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                      URL(fileURLWithPath: "/usr/local/bin/claude")]
        return places.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The agents recorded in the folder on this Mac, in order, up to the first gap.
    public static func load(root: URL) -> [AgentRecord] {
        var out: [AgentRecord] = []
        for number in 0..<limit {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path(number))) else { break }
            if let record = AgentRecord(number: number, json: data) { out.append(record) }
        }
        return out
    }

    /// Ask the bucket for each agent's record, by name, and keep what it has in the folder. Stops
    /// at the first one that is not there. Nothing is listed, so the key needs no more than it has.
    public static func fetch(root: URL, client: S3Client) {
        for number in 0..<limit {
            guard let data = try? client.get(path(number)) else { break }
            let url = root.appendingPathComponent(path(number))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
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
