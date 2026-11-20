import Foundation

/// The one message that goes with a check for updates when telemetry is off: the app version,
/// the install id, and that telemetry is off. Nothing else (decided 2026-11-20).
///
/// The makers need to know which versions are in use, to support them and to know when an old
/// one can be dropped. This is not the telemetry a person says yes or no to: it has no event of
/// the app, no pen, no system, no kind of Mac. With telemetry on, the same fact goes as the
/// ordinary event `update.check`, which says that telemetry is on, and this message is not sent.
///
/// It is made here by hand, as OTLP over HTTP in JSON, and not with the SDK: the SDK adds its
/// own attributes, and what leaves must be exactly what `docs/telemetry.md` says.
public enum UpdatePing {
    public static let eventName = "update.check"

    /// The attribute that says whether the person said yes to telemetry. False here, always:
    /// this message is sent only when they did not.
    public static let enabledKey = "telemetry.enabled"

    /// The body: one log record with an event name, under a resource of four attributes.
    public static func body(version: String, installId: String, now: Date = Date()) -> Data {
        func attribute(_ key: String, _ value: String) -> [String: Any] {
            ["key": key, "value": ["stringValue": value]]
        }
        let record: [String: Any] = [
            "timeUnixNano": String(UInt64(max(0, now.timeIntervalSince1970) * 1_000_000_000)),
            "severityNumber": 9,
            "eventName": eventName,
            "body": ["stringValue": eventName],
            "attributes": [["key": enabledKey, "value": ["boolValue": false]]],
        ]
        let message: [String: Any] = ["resourceLogs": [[
            "resource": ["attributes": [
                attribute("service.name", TelemetryPlan.serviceName),
                attribute("service.namespace", TelemetryPlan.serviceNamespace),
                attribute("service.version", version),
                attribute("service.instance.id", installId),
            ]],
            "scopeLogs": [["logRecords": [record]]],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
    }

    /// The request, to the collector of the project. Nil when the environment says that nothing
    /// leaves (`OTEL_SDK_DISABLED`), or when the address is not `https`: this message has no
    /// yes behind it, so it does not go in the clear.
    public static func request(version: String, installId: String, now: Date = Date(),
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               endpoint: String = TelemetryPlan.builtInEndpoint) -> URLRequest? {
        guard environment["OTEL_SDK_DISABLED"]?.lowercased() != "true",
              let base = URL(string: endpoint), base.scheme == "https" else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("v1/logs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(version: version, installId: installId, now: now)
        return request
    }

    /// Send it, one time. It is not kept and not sent again: the next check says the same.
    public static func send(version: String, installId: String) {
        guard let request = request(version: version, installId: installId) else { return }
        URLSession.shared.dataTask(with: request).resume()
    }
}
