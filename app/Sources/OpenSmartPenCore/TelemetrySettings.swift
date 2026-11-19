import Foundation

/// The `telemetry` part of the config: whether the app reports at all, and to where.
public struct TelemetrySettings: Codable, Equatable {
    /// Off unless the person says yes: to the question at the first start, in Settings →
    /// General, or here. It is never on by default: reading an id from a person's Mac and
    /// sending it needs their yes first.
    public var enabled = false
    /// The collector, as `https://host` or `https://host:4318`. Empty means the built-in one.
    public var endpoint = ""
    /// Headers sent with every export, for a collector that asks for a key.
    public var headers: [String: String] = [:]

    public init() {}

    /// Missing keys take their defaults, like the config this sits in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }

    /// `enabled` is always written, so the file shows the choice. The rest only when set.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        if !endpoint.isEmpty { try c.encode(endpoint, forKey: .endpoint) }
        if !headers.isEmpty { try c.encode(headers, forKey: .headers) }
    }

    private enum CodingKeys: String, CodingKey { case enabled, endpoint, headers }
}

/// Where the telemetry goes and how, worked out from three places.
///
/// The standard OpenTelemetry environment variables come first, then the `telemetry` part of the
/// config, then what is built in. The OpenTelemetry SDK for Swift reads only two of those
/// variables itself (the headers and the resource attributes), so the app reads them here.
/// Telemetry that is off stays off: no variable turns it on.
public struct TelemetryPlan: Equatable {
    /// Nil when this signal is not exported (`OTEL_LOGS_EXPORTER=none`).
    public var logs: URL?
    public var traces: URL?
    public var metrics: URL?
    public var headers: [String: String] = [:]
    public var timeout: TimeInterval = 10
    public var gzip = true
    public var serviceName = TelemetryPlan.serviceName
    /// From `OTEL_RESOURCE_ATTRIBUTES`. They replace the app's own values of the same name.
    public var resource: [String: String] = [:]
    /// Seconds between two exports of what has gathered.
    public var logDelay: TimeInterval = 5
    public var spanDelay: TimeInterval = 5
    /// Seconds between two exports of the metrics. A minute, as the specification has it.
    public var metricInterval: TimeInterval = 60
    /// True when each export carries only what was added since the last one
    /// (`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`). Otherwise each carries the
    /// total since the app started, which a collector can read after a lost export.
    public var deltaMetrics = false
    /// Things in the environment that were not understood. For the log.
    public var notes: [String] = []
    /// True when everything goes to the collector of the project: the address built into the
    /// app, which is not this Mac, with no other address from the config or the environment.
    /// What the app says about where the data is kept is a promise about that collector, so it
    /// is said only when this is true.
    public var goesToProject = false

    public static let serviceName = "opensmartpen-mac"
    public static let serviceNamespace = "opensmartpen"

    /// Where telemetry goes when the config and the environment name no collector. The project
    /// has no collector yet, so this is the standard address of a collector on the same Mac,
    /// the one an OpenTelemetry SDK uses by default. The project's own goes here when it exists.
    public static let builtInEndpoint = "http://localhost:4318"
    /// True while the built-in address is this Mac and not a collector of the project.
    public static var builtInIsLocal: Bool { url(builtInEndpoint)?.host == "localhost" }
    /// What the project's collector asks for with each export. Public by nature: this is open
    /// source, so it keeps out noise, not people.
    public static let builtInHeaders: [String: String] = [:]

    public enum Outcome: Equatable {
        case off(reason: String)
        case on(TelemetryPlan)
    }

    /// True when every address this plan sends to is `https`, so what is sent cannot be read on
    /// its way. The question at the first start says so only when this is true.
    public var isEncrypted: Bool {
        let all = [logs, traces, metrics].compactMap { $0 }
        return !all.isEmpty && all.allSatisfy { $0.scheme?.lowercased() == "https" }
    }

    /// True when the person must be asked whether the app may report to its makers.
    ///
    /// They are asked one time, at the first start that could send: the project has a collector
    /// that is not this Mac itself, or the person turned telemetry on in the config file. A
    /// build whose only collector is this Mac asks nobody, because it would send nowhere. And
    /// nothing is asked when nothing could be sent in any case (`OTEL_SDK_DISABLED`).
    public static func questionIsOwed(asked: Date?, settings: TelemetrySettings,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      builtInEndpoint: String = TelemetryPlan.builtInEndpoint) -> Bool {
        guard asked == nil else { return false }
        guard settings.enabled || url(builtInEndpoint).map({ $0.host != "localhost" }) == true else { return false }
        var wanted = settings
        wanted.enabled = true
        if case .on = resolve(settings: wanted, environment: environment, builtInEndpoint: builtInEndpoint) {
            return true
        }
        return false
    }

    public static func resolve(settings: TelemetrySettings,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               builtInEndpoint: String = TelemetryPlan.builtInEndpoint,
                               builtInHeaders: [String: String] = TelemetryPlan.builtInHeaders) -> Outcome {
        func value(_ name: String) -> String? {
            guard let text = environment[name]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return text
        }
        guard settings.enabled else { return .off(reason: "not turned on in Settings") }
        if value("OTEL_SDK_DISABLED")?.lowercased() == "true" { return .off(reason: "OTEL_SDK_DISABLED is true") }

        var plan = TelemetryPlan()
        let base = value("OTEL_EXPORTER_OTLP_ENDPOINT")
            ?? (settings.endpoint.trimmingCharacters(in: .whitespaces).isEmpty ? nil : settings.endpoint)
            ?? (builtInEndpoint.isEmpty ? nil : builtInEndpoint)

        /// A signal's own variable is the whole address. The general one is a base, and the
        /// signal's path is added to it. That is the rule of the OTLP exporter specification.
        func address(_ own: String, exporter: String, path: String) -> URL? {
            if let kind = value(exporter)?.lowercased(), kind != "otlp" {
                if kind != "none" { plan.notes.append("\(exporter)=\(kind) is not supported; only otlp and none") }
                return nil
            }
            if let whole = value(own) { return url(whole) }
            guard let base, let root = url(base) else { return nil }
            let trimmed = root.absoluteString.hasSuffix("/") ? String(root.absoluteString.dropLast()) : root.absoluteString
            return URL(string: trimmed + path)
        }
        plan.logs = address("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", exporter: "OTEL_LOGS_EXPORTER", path: "/v1/logs")
        plan.traces = address("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", exporter: "OTEL_TRACES_EXPORTER", path: "/v1/traces")
        plan.metrics = address("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", exporter: "OTEL_METRICS_EXPORTER", path: "/v1/metrics")
        guard plan.logs != nil || plan.traces != nil || plan.metrics != nil else {
            return .off(reason: "no collector to send to")
        }
        let elsewhere = ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
                         "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]
            .contains { value($0) != nil } || !settings.endpoint.trimmingCharacters(in: .whitespaces).isEmpty
        plan.goesToProject = !elsewhere && url(builtInEndpoint).map { $0.host != "localhost" } == true

        plan.headers = builtInHeaders
        plan.headers.merge(settings.headers) { _, new in new }
        plan.headers.merge(pairs(value("OTEL_EXPORTER_OTLP_HEADERS"))) { _, new in new }

        if let ms = value("OTEL_EXPORTER_OTLP_TIMEOUT").flatMap(Double.init), ms > 0 { plan.timeout = ms / 1000 }
        if let ms = value("OTEL_BLRP_SCHEDULE_DELAY").flatMap(Double.init), ms >= 0 { plan.logDelay = ms / 1000 }
        if let ms = value("OTEL_BSP_SCHEDULE_DELAY").flatMap(Double.init), ms >= 0 { plan.spanDelay = ms / 1000 }
        if let ms = value("OTEL_METRIC_EXPORT_INTERVAL").flatMap(Double.init), ms >= 1000 { plan.metricInterval = ms / 1000 }
        if let kind = value("OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE")?.lowercased() {
            if kind == "delta" { plan.deltaMetrics = true }
            else if kind != "cumulative" {
                plan.notes.append("OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=\(kind) is not supported; using cumulative")
            }
        }
        if let compression = value("OTEL_EXPORTER_OTLP_COMPRESSION")?.lowercased() {
            if compression == "none" { plan.gzip = false }
            else if compression != "gzip" { plan.notes.append("OTEL_EXPORTER_OTLP_COMPRESSION=\(compression) is not supported; using gzip") }
        }
        if let wire = value("OTEL_EXPORTER_OTLP_PROTOCOL")?.lowercased(), wire != "http/protobuf" {
            plan.notes.append("OTEL_EXPORTER_OTLP_PROTOCOL=\(wire) is not supported; using http/protobuf")
        }

        plan.resource = pairs(value("OTEL_RESOURCE_ATTRIBUTES"))
        if let name = value("OTEL_SERVICE_NAME") {
            plan.serviceName = name
        } else if let name = plan.resource["service.name"] {
            plan.serviceName = name
        }
        plan.resource["service.name"] = nil
        return .on(plan)
    }

    /// An address with a scheme and a host, or nil. `localhost:4318` is read as http.
    static func url(_ text: String) -> URL? {
        let text = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// `key1=value1,key2=value2`, with percent-encoded values, as the specification has it.
    static func pairs(_ text: String?) -> [String: String] {
        var out: [String: String] = [:]
        for piece in (text ?? "").split(separator: ",") {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces)
            let raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = raw.removingPercentEncoding ?? raw
        }
        return out
    }
}

/// What this Mac remembers about telemetry: who it is, and what the person has been told.
///
/// In a file beside the config, not in it. The config is what a person chose; this is what
/// happened. And beside the config, not in the app, so the id is the same after the app is
/// deleted and installed again.
public struct TelemetryState: Codable, Equatable {
    /// A random id, made at the first start. It says "the same install", and nothing else: it
    /// is not made from the Mac, the account or a pen.
    public var installId: String
    public var created: Date
    /// When the person answered the question at the first start, or turned telemetry on in
    /// Settings. Nil until then, and until then nothing is sent. The name is from the time
    /// when this was a notice and not a question; the file keeps it.
    public var noticed: Date?
    /// Crash reports written up to this time have been sent, or were there before telemetry was.
    public var crashesReadTo: Date?

    public static let fileName = "telemetry.json"

    public init(installId: String = UUID().uuidString.lowercased(), created: Date = Date()) {
        self.installId = installId
        self.created = created
    }

    /// Read the file, or make a new id and write it. A file that cannot be read gives a new id:
    /// a broken file must not stop the app.
    public static func load(directory: URL, now: Date = Date()) -> TelemetryState {
        let url = directory.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let state = try? decoder.decode(TelemetryState.self, from: data),
           !state.installId.isEmpty {
            return state
        }
        var state = TelemetryState(created: now)
        // Crashes from before this moment are not ours to report: nobody had been told yet.
        state.crashesReadTo = now
        state.save(directory: directory)
        return state
    }

    public func save(directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            // Not through telemetry: the thing that failed is telemetry's own file.
            Log.warn("writing \(Self.fileName) failed: \(error)", telemetry: false)
        }
    }
}
