import Foundation

public enum PublishError: Error, CustomStringConvertible {
    case git(command: String, status: Int32, output: String)
    case timeout(command: String)
    case notARepository(String)

    public var description: String {
        switch self {
        case let .git(command, status, output):
            return "git \(command) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .timeout(command):
            return "git \(command) timed out"
        case let .notARepository(path):
            return "\(path) is not a git repository"
        }
    }
}

/// Commits and pushes raw files from the notes repository. Everything runs `git` as a subprocess,
/// so the user's normal credentials (ssh agent, credential helper) apply.
public final class GitPublisher {
    public let repo: URL
    public var push: Bool
    public var timeout: TimeInterval = 120

    public init(repo: URL, push: Bool) {
        self.repo = repo
        self.push = push
    }

    /// Make sure the directory is a git repository. Creates it with a `main` branch when missing.
    /// Returns whether a remote named `origin` exists.
    @discardableResult
    public func ensureRepository() throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: repo.appendingPathComponent(".git").path) {
            _ = try run(["init", "-b", "main"])
        }
        let remotes = try run(["remote"]).output
        return remotes.split(separator: "\n").contains("origin")
    }

    /// Stage the given repo-relative paths, commit them, and push. No-op when nothing changed.
    /// Returns the short commit hash, or nil when there was nothing to commit.
    public func publish(paths: [String], message: String) throws -> String? {
        guard !paths.isEmpty else { return nil }
        _ = try run(["add", "--"] + paths)
        let staged = try run(["diff", "--cached", "--quiet"], allowedStatuses: [0, 1])
        if staged.status == 0 { return nil }
        _ = try run(["commit", "-q", "-m", message])
        let hash = try run(["rev-parse", "--short", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if push {
            try pushCurrentBranch()
        }
        return hash
    }

    public func pushCurrentBranch() throws {
        let branch = try run(["rev-parse", "--abbrev-ref", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["push", "-q", "-u", "origin", branch])
    }

    /// Commits that were made while pushing was failing.
    public func unpushedCommitCount() -> Int {
        guard let out = try? run(["rev-list", "--count", "@{u}..HEAD"], allowedStatuses: [0, 128]).output else { return 0 }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @discardableResult
    func run(_ args: [String], allowedStatuses: Set<Int32> = [0]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            throw PublishError.timeout(command: args.joined(separator: " "))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard allowedStatuses.contains(p.terminationStatus) else {
            throw PublishError.git(command: args.joined(separator: " "), status: p.terminationStatus, output: output)
        }
        return (p.terminationStatus, output)
    }
}
