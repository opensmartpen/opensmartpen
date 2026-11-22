import CryptoKit
import Foundation

/// Which bucket, and where in it. Everything a person types in Settings except the secret key.
public struct S3Settings: Codable, Equatable {
    public var bucket = ""
    /// The AWS region the bucket is in. Other services mostly ignore it but still want one signed.
    public var region = "us-east-1"
    /// Blank for AWS. Anything else that speaks S3 — R2, MinIO, Backblaze — has an address of
    /// its own, and this is it.
    public var endpoint = ""
    /// A folder inside the bucket, so one bucket can hold more than the pen's files.
    public var prefix = ""
    public var accessKeyId = ""

    public init() {}

    public var isEmpty: Bool { self == S3Settings() }

    /// Missing keys take their defaults, like the config this sits in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = S3Settings()
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? d.bucket
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? d.region
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? d.endpoint
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? d.prefix
        accessKeyId = try c.decodeIfPresent(String.self, forKey: .accessKeyId) ?? d.accessKeyId
    }
}

/// A bucket that can actually be written to: the settings, tidied, with the secret beside them.
public struct S3Account: Equatable {
    public let bucket: String
    public let region: String
    /// Scheme, host and any port — never a path, never a trailing slash.
    public let endpoint: URL
    /// No slash at either end. Empty for the top of the bucket.
    public let prefix: String
    public let accessKeyId: String
    public let secret: String

    /// Nil unless there is a bucket, a key id and a secret: all of it, or not connected.
    public init?(settings: S3Settings, secret: String?) {
        func tidy(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bucket = tidy(settings.bucket), id = tidy(settings.accessKeyId)
        let secret = tidy(secret ?? "")
        guard !bucket.isEmpty, !id.isEmpty, !secret.isEmpty else { return nil }
        let region = tidy(settings.region).isEmpty ? "us-east-1" : tidy(settings.region)
        var address = tidy(settings.endpoint)
        if address.isEmpty { address = "https://s3.\(region).amazonaws.com" }
        if !address.contains("://") { address = "https://" + address }
        guard let parsed = URLComponents(string: address), let scheme = parsed.scheme,
              let host = parsed.host, !host.isEmpty else { return nil }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = parsed.port
        guard let endpoint = base.url else { return nil }

        self.bucket = bucket
        self.region = region
        self.endpoint = endpoint
        self.prefix = tidy(settings.prefix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessKeyId = id
        self.secret = secret
    }

    /// Where a file under the notes folder goes in the bucket.
    public func key(for relativePath: String) -> String {
        prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"
    }

    /// The bucket is addressed in the path, not the host name. One shape for AWS and for
    /// everything else, and a bucket with a dot in its name still gets a valid certificate.
    public func url(forKey key: String) -> URL {
        let path = ([bucket] + key.split(separator: "/").map(String.init))
            .map(SigV4.encode).joined(separator: "/")
        return URL(string: "\(endpoint.absoluteString)/\(path)")!
    }

    /// What "the same place" means. A list of what has been uploaded is only true of the place
    /// it was uploaded to, so the list carries this and is thrown away when it changes.
    public var destination: String { "\(endpoint.absoluteString)/\(bucket)/\(prefix)" }
}

public enum S3Error: Error, LocalizedError, Equatable {
    /// The service answered, and the answer was no.
    case refused(status: Int, code: String?, message: String?)
    /// Nothing answered: no network, no such host, a timeout.
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case let .refused(status, code, message):
            let what = [code, message].compactMap { $0 }.joined(separator: ": ")
            switch status {
            case 301: return "The bucket is in another region. \(what)"
            case 403: return "The bucket refused the keys. \(what)"
            case 404: return "There is no such bucket. \(what)"
            default: return "The bucket answered \(status). \(what)"
            }
        case let .unreachable(why):
            return "The bucket cannot be reached: \(why)"
        }
    }
}

extension S3Error: TelemetryDescribed {
    /// The status and the service's own code, which name nothing. Not the service's message:
    /// those are words the service chose, and they can name an account, a key or a file.
    public var telemetryDescription: String {
        switch self {
        case let .refused(status, code, _):
            return "The bucket answered \(status)" + (code.map { ": \($0)" } ?? "")
        case let .unreachable(why):
            return "The bucket cannot be reached: \(why)"
        }
    }
}

/// How a request leaves the Mac. A protocol so that the tests can stand where the network is.
public protocol S3Transport {
    func send(_ request: URLRequest, body: Data) -> Result<(status: Int, body: Data), Error>
}

/// Puts files in a bucket, reads one back when asked for it by name, and deletes one by name when
/// a person deletes a notebook. That is all the app asks of S3, so that is all this does: no
/// listing. A key that can only write is enough to upload; reading the transcripts needs one that
/// can also read, and deleting a notebook needs one that can also delete.
public final class S3Client {
    public let account: S3Account
    private let transport: S3Transport

    public init(account: S3Account, transport: S3Transport = URLSessionTransport()) {
        self.account = account
        self.transport = transport
    }

    /// Upload one file, replacing whatever is at that path. Blocks until the service has answered,
    /// so never call it on the main thread.
    public func put(_ relativePath: String, data: Data, contentType: String, now: Date = Date()) throws {
        let request = signedPut(relativePath, data: data, contentType: contentType, now: now)
        switch transport.send(request, body: data) {
        case let .failure(error):
            throw S3Error.unreachable(error.localizedDescription)
        case let .success(response):
            guard (200..<300).contains(response.status) else {
                let text = String(decoding: response.body, as: UTF8.self)
                throw S3Error.refused(status: response.status, code: Self.tag("Code", in: text),
                                      message: Self.tag("Message", in: text))
            }
        }
    }

    /// Read one file. Nil when there is no such file, which is an answer and not a failure: a
    /// page nobody has transcribed yet has no transcript. Blocks, like `put`.
    public func get(_ relativePath: String, now: Date = Date()) throws -> Data? {
        let response = try ask(for: relativePath, now: now)
        if response.status == 404 { return nil }
        guard (200..<300).contains(response.status) else { throw Self.refusal(response) }
        return response.body
    }

    /// Delete one file. A file that is not there is already gone, which is the wanted result and
    /// not a failure. Blocks, like `put`.
    public func delete(_ relativePath: String, now: Date = Date()) throws {
        let response = try ask("DELETE", for: relativePath, now: now)
        if response.status == 404 { return }
        guard (200..<300).contains(response.status) else { throw Self.refusal(response) }
    }

    /// Prove the keys, the bucket and the region, and leave nothing in the bucket.
    ///
    /// It asks for a file that the app never writes. What matters is how the bucket says no:
    ///
    /// - "there is no such file" means the keys, the bucket and the region are all correct;
    /// - "access denied" means the keys are real and the bucket is there, but this key may not
    ///   read. A key that can only write is such a key, and it is enough to upload;
    /// - any other answer is a wrong key, a wrong secret, a wrong bucket or a wrong region, and
    ///   the bucket says which.
    ///
    /// It does not prove that the key may write. Only a write can prove that, and a test that
    /// writes leaves a file in a bucket that belongs to somebody. A key that may not write shows
    /// at the first upload, as a notification.
    public func check(now: Date = Date()) throws {
        try Telemetry.span("s3.check") { span in
            let response = try ask(for: Self.checkPath, now: now)
            span.set("http.response.status_code", .int(response.status))
            if (200..<300).contains(response.status) { return }
            let code = Self.tag("Code", in: String(decoding: response.body, as: UTF8.self))
            if response.status == 404, code != "NoSuchBucket" { return }
            if response.status == 403, code == "AccessDenied" { return }
            throw Self.refusal(response)
        }
    }

    /// The file the connection test asks for. The app never writes it.
    public static let checkPath = "opensmartpen-connection-test"

    private static func refusal(_ response: (status: Int, body: Data)) -> S3Error {
        let text = String(decoding: response.body, as: UTF8.self)
        return .refused(status: response.status, code: tag("Code", in: text), message: tag("Message", in: text))
    }

    /// One signed request with no body, answered or unreachable. What the answer means is the
    /// caller's business.
    private func ask(_ method: String = "GET", for relativePath: String, now: Date) throws -> (status: Int, body: Data) {
        let url = account.url(forKey: account.key(for: relativePath))
        var request = URLRequest(url: url)
        request.httpMethod = method
        let hash = SigV4.hex(SHA256.hash(data: Data()))
        var headers = [
            "host": SigV4.host(of: url),
            "x-amz-content-sha256": hash,
            "x-amz-date": SigV4.timestamp(now),
        ]
        headers["authorization"] = SigV4.authorization(
            method: method, url: url, headers: headers, payloadHash: hash,
            accessKeyId: account.accessKeyId, secret: account.secret, region: account.region, now: now)
        for (name, value) in headers where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        switch transport.send(request, body: Data()) {
        case let .failure(error): throw S3Error.unreachable(error.localizedDescription)
        case let .success(response): return response
        }
    }

    func signedPut(_ relativePath: String, data: Data, contentType: String, now: Date) -> URLRequest {
        let url = account.url(forKey: account.key(for: relativePath))
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let hash = SigV4.hex(SHA256.hash(data: data))
        var headers = [
            "host": SigV4.host(of: url),
            "content-type": contentType,
            "x-amz-content-sha256": hash,
            "x-amz-date": SigV4.timestamp(now),
        ]
        headers["authorization"] = SigV4.authorization(
            method: "PUT", url: url, headers: headers, payloadHash: hash,
            accessKeyId: account.accessKeyId, secret: account.secret, region: account.region, now: now)
        // URLSession writes Host itself, from the URL, and that is the value that was signed.
        for (name, value) in headers where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// S3 says what went wrong in a few lines of XML. Two fields are worth showing a person, and
    /// a parser is a lot of machinery for two fields.
    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }
}

/// AWS Signature Version 4, for one service and one kind of request.
///
/// Written out rather than taken from the AWS SDK: the SDK is some hundred packages, and what is
/// needed from it is forty lines of hashing.
public enum SigV4 {
    public static func authorization(method: String, url: URL, headers: [String: String],
                                     payloadHash: String, accessKeyId: String, secret: String,
                                     region: String, service: String = "s3", now: Date) -> String {
        let stamp = timestamp(now)
        let day = String(stamp.prefix(8))
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = parts?.percentEncodedPath ?? "/"
        let query = (parts?.percentEncodedQueryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        let names = headers.keys.map { $0.lowercased() }.sorted()
        let lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let canonicalHeaders = names
            .map { "\($0):\(lower[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signed = names.joined(separator: ";")
        let canonical = [method, path.isEmpty ? "/" : path, query, canonicalHeaders, signed, payloadHash]
            .joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))]
            .joined(separator: "\n")

        var key = hmac(Data("AWS4\(secret)".utf8), day)
        for piece in [region, service, "aws4_request"] { key = hmac(key, piece) }
        let signature = hex(hmac(key, toSign))
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signed), Signature=\(signature)"
    }

    /// `20130524T000000Z`, always in UTC.
    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// The Host header as it will be sent: a port only when it is not the scheme's own.
    static func host(of url: URL) -> String {
        guard let host = url.host else { return "" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Percent-encode one path segment the way the signature expects: everything but letters,
    /// digits and `-._~`. Foundation's own sets leave a few more alone, and one of those in a
    /// file name is a signature that does not match.
    static func encode(_ segment: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}

/// The real network.
public struct URLSessionTransport: S3Transport {
    private let session: URLSession

    public init(timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        // The laptop being offline is an ordinary state, and the caller already retries.
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest, body: Data) -> Result<(status: Int, body: Data), Error> {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(status: Int, body: Data), Error> = .failure(URLError(.unknown))
        let finish: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success((http.statusCode, data ?? Data()))
            }
            done.signal()
        }
        // A request that carries nothing is sent as one: an upload task would give a GET a body.
        let task = request.httpMethod == "GET"
            ? session.dataTask(with: request, completionHandler: finish)
            : session.uploadTask(with: request, from: body, completionHandler: finish)
        task.resume()
        done.wait()
        return result
    }
}

/// The S3 secret key, in a file of its own beside the config.
///
/// Not in the Keychain: this app is signed ad hoc, so every rebuild is a different app to macOS,
/// which asks again in a dialog that blocks the caller until somebody answers. The app is not
/// sandboxed either, so a file this process can read is one any process running as this person
/// can read, and the Keychain would be buying very little.
///
/// Not in `config.json`: the config is a plain file a person opens, edits and pastes into a bug
/// report, and a secret should not travel that way.
public enum S3Secret {
    public static var location: URL {
        Config.defaultLocation.deletingLastPathComponent().appendingPathComponent("s3-secret")
    }

    /// The secret, or nil when there is no file or it holds nothing.
    public static func read(at url: URL = location) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return nil }
        warnIfReadableByOthers(url)
        return secret
    }

    /// Store the secret, or delete the file when `value` is nil or empty.
    ///
    /// Written 0600 and atomically, and the mode is set on the file that ends up in place — a
    /// replace can otherwise leave the temporary file's own permissions behind.
    public static func write(_ value: String?, to url: URL = location) throws {
        let secret = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((secret + "\n").utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Said, not fixed silently: a person who has loosened the file's permissions on purpose
    /// should not have the app quietly undo it, and one who has not should be told.
    private static func warnIfReadableByOthers(_ url: URL) {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        else { return }
        if mode.int16Value & 0o077 != 0 {
            Log.warn("\(url.path) can be read by other users of this Mac. Fix with: chmod 600 \(url.path)")
        }
    }
}
