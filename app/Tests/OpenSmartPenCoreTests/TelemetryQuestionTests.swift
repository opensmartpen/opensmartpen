import XCTest
@testable import OpenSmartPenCore

/// When a person is asked whether the app may report to its makers, and what the app may say
/// about how it is sent.
final class TelemetryQuestionTests: XCTestCase {
    private let ours = "https://t.example.org"
    private let thisMac = "http://localhost:4318"

    private func settings(enabled: Bool = false, endpoint: String = "") -> TelemetrySettings {
        var s = TelemetrySettings()
        s.enabled = enabled
        s.endpoint = endpoint
        return s
    }

    private func owed(asked: Date? = nil, _ settings: TelemetrySettings, builtIn: String,
                      environment: [String: String] = [:]) -> Bool {
        TelemetryPlan.questionIsOwed(asked: asked, settings: settings, environment: environment,
                                     builtInEndpoint: builtIn)
    }

    func testANewSettingIsOff() {
        XCTAssertFalse(TelemetrySettings().enabled)
    }

    func testWithACollectorOfTheProjectAPersonIsAsked() {
        XCTAssertTrue(owed(settings(), builtIn: ours))
    }

    func testWithOnlyThisMacToSendToNobodyIsAsked() {
        XCTAssertFalse(owed(settings(), builtIn: thisMac))
    }

    func testAPersonWhoTurnedItOnInTheConfigIsAsked() {
        XCTAssertTrue(owed(settings(enabled: true), builtIn: thisMac))
    }

    func testAPersonIsAskedOneTimeOnly() {
        XCTAssertFalse(owed(asked: Date(), settings(), builtIn: ours))
        XCTAssertFalse(owed(asked: Date(), settings(enabled: true), builtIn: thisMac))
    }

    func testNobodyIsAskedWhenNothingCouldBeSent() {
        XCTAssertFalse(owed(settings(), builtIn: ours, environment: ["OTEL_SDK_DISABLED": "true"]))
        XCTAssertFalse(owed(settings(), builtIn: ""))
    }

    private func plan(_ endpoint: String, environment: [String: String] = [:]) -> TelemetryPlan? {
        guard case let .on(plan) = TelemetryPlan.resolve(settings: settings(enabled: true), environment: environment,
                                                         builtInEndpoint: endpoint) else { return nil }
        return plan
    }

    func testHttpsIsEncrypted() {
        XCTAssertEqual(plan(ours)?.isEncrypted, true)
    }

    func testHttpIsNotEncrypted() {
        XCTAssertEqual(plan(thisMac)?.isEncrypted, false)
    }

    func testOneSignalOverHttpMakesThePlanNotEncrypted() {
        let mixed = plan(ours, environment: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://m.example.org/v1/metrics"])
        XCTAssertEqual(mixed?.isEncrypted, false)
    }

    func testTheCollectorOfTheProjectIsOurs() {
        XCTAssertEqual(plan(ours)?.goesToProject, true)
    }

    func testThisMacIsNotTheCollectorOfTheProject() {
        XCTAssertEqual(plan(thisMac)?.goesToProject, false)
    }

    func testAnotherAddressFromTheConfigOrTheEnvironmentIsNotOurs() {
        guard case let .on(configured) = TelemetryPlan.resolve(
            settings: settings(enabled: true, endpoint: "https://other.example.org"), environment: [:],
            builtInEndpoint: ours) else { return XCTFail("no plan") }
        XCTAssertFalse(configured.goesToProject)
        XCTAssertEqual(plan(ours, environment: ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://other.example.org"])?
            .goesToProject, false)
        XCTAssertEqual(plan(ours, environment: ["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "https://other.example.org/v1/logs"])?
            .goesToProject, false)
    }

    /// The question says "encrypted on its way to us" for the project's own collector. So the
    /// address built into the app is this Mac, for a developer, or it is `https`.
    func testTheBuiltInCollectorIsThisMacOrHttps() {
        XCTAssertTrue(TelemetryPlan.builtInIsLocal || TelemetryPlan.builtInEndpoint.lowercased().hasPrefix("https://"))
    }
}
