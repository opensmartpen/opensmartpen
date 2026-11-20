import XCTest
@testable import OpenSmartPenCore

final class UpdatePingTests: XCTestCase {
    private let id = "3f2a9c1e-7b4d-4e6a-9c0d-5a1b2c3d4e5f"

    private func message() throws -> [String: Any] {
        let data = UpdatePing.body(version: "0.2.3", installId: id, now: Date(timeIntervalSince1970: 1_800_000_000))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The promise of `docs/telemetry.md`: the version, the install id and that telemetry is
    /// off, and nothing else about this Mac. A new attribute here must be a decision, not an accident.
    func testItCarriesTheVersionAndTheInstallIdAndNothingElse() throws {
        let resources = try XCTUnwrap(try message()["resourceLogs"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 1)
        let resource = try XCTUnwrap(resources[0]["resource"] as? [String: Any])
        let attributes = try XCTUnwrap(resource["attributes"] as? [[String: Any]])
        var said: [String: String] = [:]
        for attribute in attributes {
            let value = try XCTUnwrap(attribute["value"] as? [String: String])
            said[try XCTUnwrap(attribute["key"] as? String)] = value["stringValue"]
        }
        XCTAssertEqual(said, [
            "service.name": "opensmartpen-mac",
            "service.namespace": "opensmartpen",
            "service.version": "0.2.3",
            "service.instance.id": id,
        ])
    }

    func testItIsOneEventThatSaysTelemetryIsOff() throws {
        let resources = try XCTUnwrap(try message()["resourceLogs"] as? [[String: Any]])
        let scopes = try XCTUnwrap(resources[0]["scopeLogs"] as? [[String: Any]])
        let records = try XCTUnwrap(scopes[0]["logRecords"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["eventName"] as? String, "update.check")
        XCTAssertEqual(records[0]["timeUnixNano"] as? String, "1800000000000000000")
        XCTAssertEqual(Set(records[0].keys), ["timeUnixNano", "severityNumber", "eventName", "body", "attributes"])
        let attributes = try XCTUnwrap(records[0]["attributes"] as? [[String: Any]])
        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(attributes[0]["key"] as? String, "telemetry.enabled")
        XCTAssertEqual((attributes[0]["value"] as? [String: Bool])?["boolValue"], false)
    }

    func testItGoesToTheLogsOfTheCollectorOfTheProject() throws {
        let request = try XCTUnwrap(UpdatePing.request(version: "0.2.3", installId: id, environment: [:]))
        XCTAssertEqual(request.url?.absoluteString, "https://telemetry.opensmartpen.org/v1/logs")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testItIsNotSentInTheClear() {
        XCTAssertNil(UpdatePing.request(version: "0.2.3", installId: id, environment: [:],
                                        endpoint: "http://localhost:4318"))
    }

    func testTheEnvironmentCanStopIt() {
        XCTAssertNil(UpdatePing.request(version: "0.2.3", installId: id, environment: ["OTEL_SDK_DISABLED": "true"]))
    }
}
