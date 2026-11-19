import Foundation
@testable import OpenSmartPenCore
import XCTest

/// What the app reports, and above all what it does not.
///
/// `Telemetry` is one for the whole process, like `Log`, so each test starts it off and leaves
/// it off.
final class TelemetryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("opensmartpen-telemetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Telemetry.stop()
        Telemetry.scrubber = TelemetryScrubber(home: "/Users/somebody")
    }

    override func tearDownWithError() throws {
        Telemetry.stop()
        Telemetry.scrubber = TelemetryScrubber()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: off, holding, on

    func testNothingIsKeptWhileTelemetryIsOff() {
        Telemetry.event("ui.panel.opened")
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        XCTAssertEqual(sink.events, [], "what happened while it was off stays unsaid")
    }

    func testWhatIsHeldGoesOutOnlyWhenThePersonHasBeenTold() {
        Telemetry.hold()
        Telemetry.event("app.start", ["pens.paired": 1])
        Telemetry.event("pen.paired")
        XCTAssertFalse(Telemetry.isOn)

        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        XCTAssertEqual(sink.names, ["app.start", "pen.paired"], "in the order they happened")
        XCTAssertEqual(sink.events.first?.attributes["pens.paired"], .int(1))
    }

    func testWhatIsHeldIsThrownAwayWhenThePersonSaysNo() {
        Telemetry.hold()
        Telemetry.event("app.start")
        Telemetry.stop()

        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        XCTAssertEqual(sink.events, [])
    }

    func testHoldingHasALimit() {
        Telemetry.hold()
        for _ in 0..<(Telemetry.holdLimit + 50) { Telemetry.event("ui.panel.opened") }
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        XCTAssertEqual(sink.events.count, Telemetry.holdLimit)
    }

    // MARK: the log

    func testAWarningInTheLogIsReportedAndOneMarkedLocalIsNot() {
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        Log.info("pages go to the bucket")
        Log.warn("connect timed out")
        Log.error("upload failed (1x): The bucket refused the keys.")
        Log.warn("holiday-notes.heic is not a picture; not added", telemetry: false)

        XCTAssertEqual(sink.events.map(\.body), ["connect timed out", "upload failed (1x): The bucket refused the keys."])
        XCTAssertEqual(sink.events.map(\.level), [.warn, .error])
        XCTAssertEqual(sink.names, [], "a line from the log has words and no event name")
        // Where in the source the line was written: the same words for everybody, not a path of this Mac.
        XCTAssertEqual(sink.events[0].attributes["code.file.path"], .string("OpenSmartPenCoreTests/TelemetryTests.swift"))
        XCTAssertNotNil(sink.events[0].attributes["code.line.number"])
        XCTAssertEqual(sink.total(.problems, where: ["log.level": "warn"]), 2, "the local one is counted, and not said")
        XCTAssertEqual(sink.total(.problems, where: ["log.level": "error"]), 1)
    }

    func testANoticeIsReportedByItsKindAndNeverByItsWords() {
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        let notifier = DedupingNotifier(RecordingNotifier())
        notifier.post(Notice(key: "battery-9c7bd2000001", title: "Pen battery at 12%", body: "Charge Anna's red pen soon."))
        notifier.post(Notice(key: "paired-9c7bd2000001", title: "Open Smart Pen paired with LAMY", body: "…"))
        notifier.post(Notice(key: "publish-failed", title: "Open Smart Pen cannot upload notes", body: "…"))

        XCTAssertEqual(sink.names, ["notice.posted", "notice.posted", "notice.posted"])
        XCTAssertEqual(sink.events.map { $0.attributes["notice.key"] }, [.string("battery"), .string("paired"), .string("publish-failed")])
        XCTAssertEqual(sink.events[0].attributes["pen.mac"], .string("9c7bd2000001"))
        XCTAssertNil(sink.events[2].attributes["pen.mac"])
        XCTAssertEqual(sink.events.map(\.level), [.warn, .info, .warn], "a pen that was paired is news, not a problem")
        for event in sink.events {
            XCTAssertNil(event.body, "the words name the pen as its owner named it")
        }
    }

    func testANoticeAboutAPenKnownOnlyByItsBluetoothIdentifierHasAKindToo() {
        let notice = Notice(key: "drain-stalled-6F9619FF-8B86-D011-B42D-00C04FC964FF", title: "", body: "")
        XCTAssertEqual(notice.kind, "drain-stalled")
        XCTAssertNil(notice.penMac)
    }

    // MARK: what is taken out

    func testPrivateTextIsTakenOutOfEverythingThatLeaves() {
        var scrubber = TelemetryScrubber(home: "/Users/somebody")
        scrubber.hide("family-notes", as: "bucket")
        scrubber.hide("pen", as: "folder")
        scrubber.hide("AKIAIOSFODNN7EXAMPLE", as: "key-id")
        scrubber.hide("r2", as: "endpoint")       // too short to hide without wrecking the message
        Telemetry.scrubber = scrubber
        let sink = RecordingTelemetry()
        Telemetry.start(sink)

        Log.error("writing /Users/somebody/OpenSmartPen/pens/annas-red-pen.json failed: no space left")
        Log.error("upload failed: The bucket family-notes refused AKIAIOSFODNN7EXAMPLE")
        Telemetry.event("bucket.connect", ["bucket.error": "NoSuchBucket: family-notes"])

        XCTAssertEqual(sink.events[0].body, "writing ~/OpenSmartPen/pens/<pen>.json failed: no space left")
        XCTAssertEqual(sink.events[1].body, "upload failed: The bucket <bucket> refused <key-id>")
        XCTAssertEqual(sink.events[2].attributes["bucket.error"], .string("NoSuchBucket: <bucket>"))
    }

    func testAVeryLongMessageIsCut() {
        let cleaned = TelemetryScrubber(home: "/Users/somebody").clean(String(repeating: "x", count: 20_000))
        XCTAssertEqual(cleaned.count, TelemetryScrubber.limit + 1)
    }

    // MARK: spans

    func testWorkTimedInsideOtherWorkIsAPartOfIt() throws {
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        struct Refused: LocalizedError { var errorDescription: String? { "The bucket refused the keys." } }

        XCTAssertThrowsError(try Telemetry.span("sync.publish", ["sync.pages": 2]) { outer in
            outer.set("sync.files", 3)
            Telemetry.span("pages.draw") { _ in }
            try Telemetry.span("s3.upload") { _ in throw Refused() }
        })

        XCTAssertEqual(sink.spans.map(\.name), ["sync.publish", "pages.draw", "s3.upload"])
        XCTAssertEqual(sink.spans.map(\.parent), [nil, "sync.publish", "sync.publish"])
        XCTAssertEqual(sink.spans[0].attributes, ["sync.pages": .int(2), "sync.files": .int(3)])
        XCTAssertNil(sink.spans[1].error)
        XCTAssertEqual(sink.spans[2].error, "The bucket refused the keys.")
        XCTAssertEqual(sink.spans[0].error, "The bucket refused the keys.", "a failed part fails the whole")
        XCTAssertTrue(sink.spans.allSatisfy(\.ended))
    }

    func testEachPieceOfTimedWorkIsMeasuredOnceByItsNameAndHowItEnded() {
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        Telemetry.span("pages.draw") { _ in }
        let drain = Telemetry.begin("pen.drain", ["pen.mac": "9c7bd2000001"])
        drain.end(error: "the pen disconnected")
        drain.end(error: "superseded")      // a pen that drops ends the same work a second time

        let durations = sink.measurements.filter { $0.metric == .operationDuration }
        XCTAssertEqual(durations.map(\.attributes), [
            ["operation": "pages.draw", "outcome": "ok"],
            ["operation": "pen.drain", "outcome": "error"],
        ], "the name and the outcome, and never the address of the pen")
        XCTAssertTrue(durations.allSatisfy { $0.value >= 0 && $0.value < 5 })
        XCTAssertEqual(sink.spans[1].error, "the pen disconnected", "the first ending stands")
    }

    func testWhatHappensInsideTimedWorkIsTiedToIt() {
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        Telemetry.event("ui.sync_now")
        Telemetry.span("sync.publish") { _ in
            Telemetry.span("s3.upload") { _ in Log.error("upload failed (1x): The bucket refused the keys.") }
            Telemetry.event("sync.recovered")
        }
        XCTAssertEqual(sink.eventSpans, [nil, "s3.upload", "sync.publish"])
    }

    // MARK: metrics

    func testNumbersWaitToo_ACounterAddsUpAndAGaugeKeepsTheLast() {
        Telemetry.hold()
        for _ in 0..<(Telemetry.holdLimit * 2) { Telemetry.count(.strokes, ["stroke.source": "live"]) }
        Telemetry.count(.strokes, ["stroke.source": "offline"], by: 40)
        Telemetry.measure(.pagesPending, 3)
        Telemetry.measure(.pagesPending, 1)
        Telemetry.event("app.start")

        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        XCTAssertEqual(sink.names, ["app.start"], "an hour of writing does not push the events out")
        XCTAssertEqual(sink.total(.strokes, where: ["stroke.source": "live"]), Double(Telemetry.holdLimit * 2))
        XCTAssertEqual(sink.total(.strokes, where: ["stroke.source": "offline"]), 40)
        XCTAssertEqual(sink.measurements.filter { $0.metric == .pagesPending }.map(\.value), [1])
    }

    func testNoNumberIsKeptWhileTelemetryIsOff() {
        Telemetry.count(.strokes, by: 3)
        Telemetry.measure(.pagesPending, 2)
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        XCTAssertEqual(sink.measurements, [])
    }

    func testEveryMetricHasAUnitAndIsOnTheListOfWhatIsSent() throws {
        XCTAssertEqual(Set(TelemetryMetric.all.map(\.name)).count, TelemetryMetric.all.count, "a name is used once")
        let list = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/telemetry.md")
        let text = try String(contentsOf: list, encoding: .utf8)
        for metric in TelemetryMetric.all {
            XCTAssertFalse(metric.unit.isEmpty, metric.name)
            XCTAssertFalse(metric.description.isEmpty, metric.name)
            XCTAssertTrue(text.contains("`\(metric.name)`"), "\(metric.name) is sent and is not in docs/telemetry.md")
        }
    }

    func testAnUploadIsReportedWithHowMuchWasWrittenAndNotWhat() throws {
        let sink = RecordingTelemetry()
        Telemetry.start(sink)
        let notes = root.appendingPathComponent("notes")
        let bucket = FakeBucket()
        var settings = S3Settings()
        settings.bucket = "notes"
        settings.accessKeyId = "AKIAEXAMPLE"
        let sync = S3Sync(root: notes, ledger: root.appendingPathComponent("s3-uploaded.json"))
        sync.connect(S3Client(account: try XCTUnwrap(S3Account(settings: settings, secret: "secret")), transport: bucket))
        let store = RawStore(root: notes, app: "c", sdk: "s")
        let books = BookRegistry(root: notes)
        let coordinator = SyncCoordinator(store: store, router: PageRouter(books: books, store: store),
                                          tracker: QuietTracker(), publisher: sync, notifier: RecordingNotifier(),
                                          quietWindow: 30)
        let page = PageID(section: 3, owner: 27, book: 450, page: 1)
        let strokes = (0..<3).map { i in
            Stroke(page: page, start: 1000 + i * 100, end: 1010 + i * 100,
                   dots: [DotSample(x: Double(i), y: 2, force: 0.3, dt: 0), DotSample(x: Double(i) + 0.5, y: 2.5, force: 0.4, dt: 12)],
                   source: .live, penMac: "M", firmware: "F")
        }
        coordinator.ingestLive(strokes)

        let done = expectation(description: "uploaded")
        coordinator.publishAll { _ in done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(sink.names, ["book.added"])
        XCTAssertEqual(sink.events[0].attributes["book.surface"], .string("s3/o27/b450"))
        let publish = try XCTUnwrap(sink.spans.first { $0.name == "sync.publish" })
        XCTAssertEqual(publish.attributes["sync.reason"], .string("manual"))
        XCTAssertEqual(publish.attributes["sync.pages"], .int(1))
        XCTAssertEqual(publish.attributes["strokes.live"], .int(3))
        XCTAssertEqual(publish.attributes["strokes.offline"], .int(0))
        XCTAssertEqual(sink.spans.first { $0.name == "s3.upload" }?.parent, "sync.publish")
        let puts = sink.spans.filter { $0.name == "s3.put" }
        XCTAssertEqual(Set(puts.map { $0.attributes["file.kind"] }), [.string("book"), .string("strokes")])
        XCTAssertTrue(puts.allSatisfy { $0.parent == "s3.upload" })
        // The same upload, as numbers that are added up.
        XCTAssertEqual(sink.total(.strokes, where: ["stroke.source": "live"]), 3)
        XCTAssertEqual(sink.total(.pagesPublished, where: ["sync.reason": "manual"]), 1)
        XCTAssertEqual(sink.total(.filesUploaded), Double(puts.count))
        XCTAssertEqual(sink.total(.filesUploaded, where: ["file.kind": "strokes"]), 1)
        XCTAssertGreaterThan(sink.total(.bytesUploaded, where: ["file.kind": "strokes"]), 0)
        XCTAssertEqual(Set(sink.measurements.filter { $0.metric == .operationDuration }.compactMap { $0.attributes["operation"] }),
                       Set(sink.spans.map { TelemetryValue.string($0.name) }))
        for measurement in sink.measurements {
            for case let .string(text) in measurement.attributes.values {
                XCTAssertFalse(text.contains("/"), "\(measurement.metric.name) carries a path: \(text)")
            }
        }
        // The folder of a notebook, the name of a file: none of it is on any span.
        for span in sink.spans {
            for case let .string(text) in span.attributes.values {
                XCTAssertFalse(text.contains("books/"), "\(span.name) carries a path: \(text)")
            }
        }
    }

    func testWhyAnUploadBeganIsOneOfAFewWords() {
        XCTAssertEqual(SyncCoordinator.kind(of: "no pen event for 30 s"), "quiet")
        XCTAssertEqual(SyncCoordinator.kind(of: "offline drain of book 450"), "drain")
        XCTAssertEqual(SyncCoordinator.kind(of: "manual"), "manual")
        XCTAssertEqual(SyncCoordinator.kind(of: "photo"), "photo")
        XCTAssertEqual(SyncCoordinator.kind(of: "something new"), "other")
    }

    // MARK: where it goes

    /// Telemetry as a person who turned it on has it. The default is off.
    private var on: TelemetrySettings {
        var settings = TelemetrySettings()
        settings.enabled = true
        return settings
    }

    private func plan(_ settings: TelemetrySettings? = nil, _ environment: [String: String] = [:],
                      builtIn: String = "") -> TelemetryPlan.Outcome {
        TelemetryPlan.resolve(settings: settings ?? on, environment: environment, builtInEndpoint: builtIn,
                              builtInHeaders: [:])
    }

    func testWithNoCollectorNothingIsSent() {
        XCTAssertEqual(plan(), .off(reason: "no collector to send to"))
    }

    func testItIsOffUntilAPersonTurnsItOn() {
        XCTAssertFalse(TelemetrySettings().enabled)
        XCTAssertFalse(Config().telemetry.enabled)
        XCTAssertEqual(TelemetryPlan.resolve(settings: TelemetrySettings(), environment: [:]),
                       .off(reason: "not turned on in Settings"))
    }

    func testTurnedOnWithNoCollectorNamedItGoesToTheCollectorOfTheProject() {
        guard case let .on(plan) = TelemetryPlan.resolve(settings: on, environment: [:]) else { return XCTFail("off") }
        XCTAssertEqual(plan.logs?.absoluteString, "https://telemetry.opensmartpen.org/v1/logs")
        XCTAssertEqual(plan.traces?.absoluteString, "https://telemetry.opensmartpen.org/v1/traces")
        XCTAssertEqual(plan.metrics?.absoluteString, "https://telemetry.opensmartpen.org/v1/metrics")
        XCTAssertFalse(TelemetryPlan.builtInIsLocal)
        XCTAssertTrue(plan.isEncrypted)
        XCTAssertTrue(plan.goesToProject)
    }

    func testWhatIsOffStaysOffWhateverTheEnvironmentSays() {
        let settings = TelemetrySettings()
        XCTAssertEqual(plan(settings, ["OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318"], builtIn: "https://t.example.org"),
                       .off(reason: "not turned on in Settings"))
    }

    func testTheStandardVariableTurnsItOff() {
        XCTAssertEqual(plan(on, ["OTEL_SDK_DISABLED": "TRUE"], builtIn: "https://t.example.org"),
                       .off(reason: "OTEL_SDK_DISABLED is true"))
    }

    func testTheGeneralEndpointIsABaseAndASignalsOwnIsTheWholeAddress() throws {
        guard case let .on(plan) = plan(on, [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318/",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://localhost:9999/custom",
        ]) else { return XCTFail("off") }
        XCTAssertEqual(plan.logs?.absoluteString, "http://localhost:4318/v1/logs")
        XCTAssertEqual(plan.traces?.absoluteString, "http://localhost:9999/custom")
    }

    func testTheEnvironmentComesBeforeTheConfigAndTheConfigBeforeWhatIsBuiltIn() {
        var settings = on
        guard case let .on(builtIn) = plan(settings, [:], builtIn: "https://t.example.org") else { return XCTFail("off") }
        XCTAssertEqual(builtIn.logs?.absoluteString, "https://t.example.org/v1/logs")

        settings.endpoint = "collector.internal:4318"
        guard case let .on(configured) = plan(settings, [:], builtIn: "https://t.example.org") else { return XCTFail("off") }
        XCTAssertEqual(configured.logs?.absoluteString, "http://collector.internal:4318/v1/logs")

        guard case let .on(fromEnvironment) = plan(settings, ["OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318"],
                                                   builtIn: "https://t.example.org") else { return XCTFail("off") }
        XCTAssertEqual(fromEnvironment.traces?.absoluteString, "http://localhost:4318/v1/traces")
    }

    func testHeadersAreMergedAndTheEnvironmentWins() {
        var settings = on
        settings.endpoint = "https://t.example.org"
        settings.headers = ["authorization": "from-config", "x-team": "pen"]
        guard case let .on(plan) = plan(settings, ["OTEL_EXPORTER_OTLP_HEADERS": "authorization=Bearer%20abc, x-extra=1"])
        else { return XCTFail("off") }
        XCTAssertEqual(plan.headers, ["authorization": "Bearer abc", "x-team": "pen", "x-extra": "1"])
    }

    func testTheOtherStandardVariablesAreRead() {
        guard case let .on(plan) = plan(on, [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318",
            "OTEL_EXPORTER_OTLP_TIMEOUT": "2500",
            "OTEL_EXPORTER_OTLP_COMPRESSION": "none",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
            "OTEL_BLRP_SCHEDULE_DELAY": "1000",
            "OTEL_BSP_SCHEDULE_DELAY": "500",
            "OTEL_TRACES_EXPORTER": "none",
            "OTEL_SERVICE_NAME": "pen-dev",
            "OTEL_RESOURCE_ATTRIBUTES": "deployment.environment.name=dev,service.name=ignored,team=a%20b",
        ]) else { return XCTFail("off") }
        XCTAssertEqual(plan.timeout, 2.5)
        XCTAssertFalse(plan.gzip)
        XCTAssertEqual(plan.logDelay, 1)
        XCTAssertEqual(plan.spanDelay, 0.5)
        XCTAssertNil(plan.traces, "OTEL_TRACES_EXPORTER=none")
        XCTAssertNotNil(plan.logs)
        XCTAssertEqual(plan.serviceName, "pen-dev", "OTEL_SERVICE_NAME comes before service.name in the attributes")
        XCTAssertEqual(plan.resource, ["deployment.environment.name": "dev", "team": "a b"])
        XCTAssertEqual(plan.notes, ["OTEL_EXPORTER_OTLP_PROTOCOL=grpc is not supported; using http/protobuf"])
    }

    func testWithEverySignalTurnedOffTelemetryIsOff() {
        XCTAssertEqual(plan(on, ["OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318", "OTEL_LOGS_EXPORTER": "none",
                                 "OTEL_TRACES_EXPORTER": "none", "OTEL_METRICS_EXPORTER": "none"]),
                       .off(reason: "no collector to send to"))
    }

    func testMetricsHaveAnAddressAnIntervalAndAWayToBeAddedUp() {
        guard case let .on(usual) = plan(on, ["OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318"]) else { return XCTFail("off") }
        XCTAssertEqual(usual.metrics?.absoluteString, "http://localhost:4318/v1/metrics")
        XCTAssertEqual(usual.metricInterval, 60)
        XCTAssertFalse(usual.deltaMetrics)

        guard case let .on(changed) = plan(on, [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318",
            "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://localhost:9090/api/v1/otlp/v1/metrics",
            "OTEL_METRIC_EXPORT_INTERVAL": "15000",
            "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "Delta",
        ]) else { return XCTFail("off") }
        XCTAssertEqual(changed.metrics?.absoluteString, "http://localhost:9090/api/v1/otlp/v1/metrics")
        XCTAssertEqual(changed.metricInterval, 15)
        XCTAssertTrue(changed.deltaMetrics)

        guard case let .on(without) = plan(on, ["OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318",
                                                "OTEL_METRICS_EXPORTER": "none"]) else { return XCTFail("off") }
        XCTAssertNil(without.metrics)
        XCTAssertNotNil(without.logs)
    }

    // MARK: the config and the state

    func testAnOlderConfigHasTelemetryOffAndTheChoiceIsWrittenDown() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"quietSeconds": 60}"#.utf8))
        XCTAssertFalse(old.telemetry.enabled)
        XCTAssertEqual(old.telemetry.endpoint, "")

        var config = Config()
        config.telemetry.enabled = true
        let url = root.appendingPathComponent("config.json")
        try config.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"telemetry\""), text)
        XCTAssertFalse(text.contains("\"endpoint\""), "only what was set is written")
        XCTAssertEqual(try Config.loadOrCreate(at: url).telemetry, config.telemetry)
    }

    func testTheInstallKeepsItsIdAndRemembersThatThePersonWasTold() {
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        var first = TelemetryState.load(directory: root, now: made)
        XCTAssertEqual(first.installId.count, 36)
        XCTAssertNil(first.noticed)
        XCTAssertEqual(first.crashesReadTo, made, "a crash from before the install is not reported")

        first.noticed = Date(timeIntervalSince1970: 1_800_000_100)
        first.save(directory: root)
        let again = TelemetryState.load(directory: root)
        XCTAssertEqual(again, first)
        XCTAssertNotEqual(TelemetryState.load(directory: root.appendingPathComponent("another-mac")).installId,
                          first.installId)
    }

    // MARK: crashes

    private static let crash = #"""
    {"app_name":"opensmartpen","timestamp":"2026-11-12 14:30:39.00 +0100","app_version":"0.2.0","slice_uuid":"11111111-2222-3333-4444-555555555555","bundleID":"org.opensmartpen.app","bug_type":"309","os_version":"macOS 27.2 (27C100)","incident_id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"opensmartpen"}
    {
      "procName": "opensmartpen",
      "procPath": "/Users/somebody/Applications/Open Smart Pen.app/Contents/MacOS/opensmartpen",
      "captureTime": "2026-11-12 14:30:37.6057 +0100",
      "exception": {"codes": "0x0000000000000001, 0x0000000100a0b0c0", "type": "EXC_BREAKPOINT", "signal": "SIGTRAP"},
      "termination": {"flags": 0, "code": 5, "namespace": "SIGNAL", "indicator": "Trace/BPT trap: 5"},
      "asi": {"libswiftCore.dylib": ["Fatal error: Index out of range"]},
      "faultingThread": 1,
      "threads": [
        {"id": 100, "frames": [{"imageOffset": 10, "symbol": "mach_msg", "symbolLocation": 4, "imageIndex": 1}]},
        {"id": 101, "triggered": true, "frames": [
          {"imageOffset": 4660, "symbol": "_assertionFailure", "symbolLocation": 172, "imageIndex": 1},
          {"imageOffset": 74565, "imageIndex": 0},
          {"imageOffset": 3, "symbol": "main", "symbolLocation": 12, "imageIndex": 0}
        ]}
      ],
      "usedImages": [
        {"name": "opensmartpen", "path": "/Users/somebody/Applications/Open Smart Pen.app/Contents/MacOS/opensmartpen", "uuid": "99999999-8888-7777-6666-555555555555"},
        {"name": "libswiftCore.dylib", "path": "/usr/lib/swift/libswiftCore.dylib", "uuid": "00000000-0000-0000-0000-000000000001"}
      ]
    }
    """#

    func testACrashReportIsReadAsWhatHappenedAndWhere() throws {
        let report = try XCTUnwrap(CrashReport.parse(Data(Self.crash.utf8), process: "opensmartpen"))
        XCTAssertEqual(report.kind, "EXC_BREAKPOINT (SIGTRAP)")
        XCTAssertEqual(report.message, "Trace/BPT trap: 5\nFatal error: Index out of range")
        XCTAssertEqual(report.stack, """
        0 libswiftCore.dylib _assertionFailure + 172
        1 opensmartpen 0x12345
        2 opensmartpen main + 12
        """)
        XCTAssertEqual(report.incident, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(report.appVersion, "0.2.0")
        XCTAssertEqual(report.binaryUUID, "99999999-8888-7777-6666-555555555555")
        XCTAssertEqual(report.time.timeIntervalSince1970, 1_794_490_239, accuracy: 1)
        XCTAssertFalse(report.stack.contains("/Users"), "the name of a binary, never its path")
    }

    func testOnlyThisAppsNewCrashesAreRead() throws {
        let folder = root.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.crash.utf8).write(to: folder.appendingPathComponent("opensmartpen-2026-11-12-143039.ips"))
        try Data(Self.crash.replacingOccurrences(of: "opensmartpen\"", with: "opensmartpen-design\"").utf8)
            .write(to: folder.appendingPathComponent("opensmartpen-design-2026-11-12-143039.ips"))
        try Data(Self.crash.utf8).write(to: folder.appendingPathComponent("Safari-2026-11-12-143039.ips"))
        try Data("not a report".utf8).write(to: folder.appendingPathComponent("opensmartpen-broken.ips"))

        let found = CrashReport.recent(in: folder, process: "opensmartpen", after: .distantPast)
        XCTAssertEqual(found.map(\.incident), ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])
        XCTAssertEqual(CrashReport.recent(in: folder, process: "opensmartpen", after: Date().addingTimeInterval(60)), [],
                       "a report that was already read is not read again")
    }
}
