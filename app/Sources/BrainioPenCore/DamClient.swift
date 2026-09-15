import Foundation

/// Which agent workspace the pages are handed to, and the key that opens it.
///
/// The key is not kept here on disk: it lives in the Keychain (`Keychain.damApiKey`), because the
/// config file is plain JSON a person edits by hand and a bearer token in it would be read by
/// anything that can read the home directory.
public struct DamAccount: Equatable, Sendable {
    /// `https://dam.example.com`, with or without a trailing slash.
    public let host: String
    /// The agent's id, `agent-…`, not its name.
    public let agentId: String
    /// A `pk_…` API key with the `agents:operate` scope, bound to this agent.
    public let apiKey: String

    public init(host: String, agentId: String, apiKey: String) {
        self.host = host
        self.agentId = agentId
        self.apiKey = apiKey
    }
}

/// A file as the agent's workspace returns it.
public struct DamFile: Equatable, Sendable {
    public let path: String
    /// Bytes, decoded already: the wire carries text as UTF-8 and anything else as base64.
    public let data: Data
    public let mimeType: String
    /// Last modification, milliseconds since the epoch, as the pod sees it.
    public let mtimeMs: Double

    public var text: String? { String(data: data, encoding: .utf8) }
}

public struct DamAgent: Equatable, Identifiable {
    public let id: String
    public let name: String
}

public enum DamError: Error, LocalizedError, Equatable {
    /// An API key sent to a plain-http host is an API key given away.
    case insecureHost(String)
    case noAccount
    case transport(String)
    /// The server said no: a tRPC error, or the proxy's own refusal.
    case refused(procedure: String, detail: String)
    case notFound(path: String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .insecureHost(host):
            return "\(host) is not https, so the API key would travel in the clear"
        case .noAccount:
            return "no DAM agent is configured"
        case let .transport(detail):
            return "DAM is unreachable: \(detail)"
        case let .refused(procedure, detail):
            return "DAM refused \(procedure): \(detail)"
        case let .notFound(path):
            return "\(path) is not in the agent's workspace"
        case let .malformed(detail):
            return "DAM answered with something unreadable: \(detail)"
        }
    }
}

/// The agent's workspace: somewhere to put a file and somewhere to get one back. A protocol so a
/// test can hold the other end of it.
public protocol DamWorkspace: Sendable {
    func upload(path: String, data: Data, contentType: String, overwrite: Bool) async throws
    func read(path: String) async throws -> DamFile
}

/// Talks to one DAM agent's workspace over the api-server's tRPC surface.
///
/// Two paths, deliberately different. `files.upload` and `files.read` go through
/// `/api/agents/<id>/trpc/…`, the proxy that waits for the agent to be ready — so a page handed to
/// a hibernated agent wakes it rather than failing. `agents.list` is owner-wide and goes to
/// `/api/trpc/…` instead; it exists so a person can pick an agent by name once and never see an id.
///
/// Plain JSON on the wire: neither router installs a transformer.
public final class DamClient: DamWorkspace {
    private let account: DamAccount
    private let session: URLSession

    /// - Throws: `DamError.insecureHost` unless the host is https or loopback.
    public init(account: DamAccount, session: URLSession = .shared) throws {
        guard Self.isSecure(account.host) else { throw DamError.insecureHost(account.host) }
        self.account = account
        self.session = session
    }

    /// Loopback is allowed so a local DAM can be worked against; everything else must be https.
    static func isSecure(_ host: String) -> Bool {
        guard let url = URL(string: host), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let name = url.host?.lowercased() else { return false }
        return name == "localhost" || name == "127.0.0.1" || name == "::1"
    }

    private var base: String { account.host.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
    private var agentTrpc: String { "\(base)/api/agents/\(account.agentId)/trpc" }
    private var ownerTrpc: String { "\(base)/api/trpc" }

    // MARK: - Procedures

    /// Write a file into the agent's workspace, at a path relative to its working directory.
    ///
    /// Overwrites by default. A page read twice is the normal case — the paper is written on again
    /// — and refusing the second upload would leave the agent looking at the older image.
    public func upload(path: String, data: Data, contentType: String, overwrite: Bool = true) async throws {
        let input: [String: Any] = [
            "path": path,
            "contentBase64": data.base64EncodedString(),
            "contentType": contentType,
            "overwrite": overwrite,
        ]
        _ = try await call(url: "\(agentTrpc)/files.upload", procedure: "files.upload",
                           input: input, method: "POST", timeout: 180, subject: path)
    }

    /// Read a file back out of the agent's workspace.
    public func read(path: String) async throws -> DamFile {
        let payload = try await call(url: "\(agentTrpc)/files.read", procedure: "files.read",
                                     input: ["path": path], method: "GET", timeout: 60, subject: path)
        guard let object = payload as? [String: Any],
              let content = object["content"] as? String,
              let mime = object["mimeType"] as? String,
              let mtime = object["mtimeMs"] as? Double
        else { throw DamError.malformed("files.read returned no file") }
        let binary = object["binary"] as? Bool ?? false
        guard let data = binary ? Data(base64Encoded: content) : content.data(using: .utf8) else {
            throw DamError.malformed("the content of \(path) could not be decoded")
        }
        return DamFile(path: path, data: data, mimeType: mime, mtimeMs: mtime)
    }

    /// Every agent this key can see, so a person chooses one by name.
    public func agents() async throws -> [DamAgent] {
        let payload = try await call(url: "\(ownerTrpc)/agents.list", procedure: "agents.list",
                                     input: nil, method: "GET", timeout: 30)
        guard let rows = payload as? [[String: Any]] else {
            throw DamError.malformed("agents.list returned no list")
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return DamAgent(id: id, name: row["name"] as? String ?? id)
        }
    }

    // MARK: - The wire

    private func call(url: String, procedure: String, input: Any?, method: String,
                      timeout: TimeInterval, subject: String? = nil) async throws -> Any? {
        var address = url
        var body: Data?
        if let input {
            // Slashes unescaped: every input we send is mostly a path, and `pen\/p4.png` in a query
            // is legal JSON but unreadable in a log and in a test.
            let json = try JSONSerialization.data(withJSONObject: input,
                                                  options: [.sortedKeys, .withoutEscapingSlashes])
            if method == "GET" {
                let query = String(decoding: json, as: UTF8.self)
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
                address += "?input=\(query)"
            } else {
                body = json
            }
        }
        guard let target = URL(string: address) else { throw DamError.malformed("bad URL \(address)") }

        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DamError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let object = parsed as? [String: Any]

        // A tRPC error and the proxy's own refusal look different on the wire, and both can arrive
        // with a 200 or without one. Read the body first; fall back to the status line.
        if let error = object?["error"] as? [String: Any] {
            throw refusal(procedure, subject, error["message"] as? String ?? "\(error)")
        }
        if let error = object?["error"] as? String {
            let message = object?["message"] as? String
            throw refusal(procedure, subject, [error, message].compactMap { $0 }.joined(separator: ": "))
        }
        guard (200..<300).contains(status) else {
            throw refusal(procedure, subject, "HTTP \(status)")
        }
        guard let result = object?["result"] as? [String: Any] else {
            throw DamError.malformed("\(procedure) returned no result")
        }
        return result["data"]
    }

    /// A missing file is not a fault to report to a person: the page has simply never been read,
    /// which is the ordinary state of a page the first time it is sent.
    private func refusal(_ procedure: String, _ subject: String?, _ detail: String) -> DamError {
        let missing = detail.uppercased().contains("NOT_FOUND") || detail.lowercased().contains("not found")
        if missing, let subject { return .notFound(path: subject) }
        return .refused(procedure: procedure, detail: detail)
    }
}

extension CharacterSet {
    /// `.urlQueryAllowed` lets `&`, `+` and `=` through, which is exactly wrong inside one value.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
}
