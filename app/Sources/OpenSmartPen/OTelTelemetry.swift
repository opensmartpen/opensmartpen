import Foundation
import OpenSmartPenCore
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import PersistenceExporter

/// Sends the app's events, spans and metrics with the OpenTelemetry SDK, over OTLP/HTTP.
///
/// An event is a log record with an event name. A warning or an error from the log is a log
/// record with only a body. A span is a span. A metric is an instrument of the SDK, made the
/// first time a number is given to it: a counter, a histogram or a gauge.
///
/// What is to be sent is written to disk first, in the caches folder, and sent from there. A
/// laptop is often offline, and this app is used most where it is: away from the desk. What was
/// not sent is sent at the next start, up to a week later.
///
/// The providers are held here and not registered as the SDK's globals. Nothing else in the
/// process uses OpenTelemetry, and a global that is set cannot be taken back when the person
/// turns telemetry off.
final class OTelTelemetry: TelemetrySink {
    private let logger: OpenTelemetryApi.Logger
    private let tracer: Tracer
    private let tracerProvider: TracerProviderSdk
    private let logProcessor: BatchLogRecordProcessor?
    private let meterProvider: MeterProviderSdk?
    private let meter: MeterSdk?
    /// The instruments made so far, by the name of the metric. One lock keeps the tables.
    private let instruments = NSLock()
    private var counters: [String: LongCounterSdk] = [:]
    private var histograms: [String: DoubleHistogramMeterSdk] = [:]
    private var gauges: [String: DoubleGaugeSdk] = [:]
    /// One run of the app, from start to stop. It ties the events of one run together.
    private let session = UUID().uuidString.lowercased()

    init(plan: TelemetryPlan, resource: Resource, queue: URL) {
        // The SDK reads `OTEL_EXPORTER_OTLP_HEADERS` itself, and when it finds it, it drops the
        // headers it was given. The plan has already merged the two, so the SDK is told there
        // is nothing to read.
        let config = OtlpConfiguration(timeout: plan.timeout,
                                       compression: plan.gzip ? .gzip : .none,
                                       headers: plan.headers.map { ($0.key, $0.value) })
        let none: [(String, String)]? = nil
        try? FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)

        var logProcessors: [LogRecordProcessor] = []
        var batch: BatchLogRecordProcessor?
        if let url = plan.logs {
            // The queue on disk does the retrying, so the exporter must not also keep a copy.
            let exporter = OtlpHttpLogExporter(endpoint: url, config: config, envVarHeaders: none,
                                               requeueOnFailure: false)
            let folder = queue.appendingPathComponent("logs")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = try? PersistenceLogExporterDecorator(logRecordExporter: exporter, storageURL: folder,
                                                            performancePreset: Self.queuePreset)
            let processor = BatchLogRecordProcessor(logRecordExporter: kept ?? exporter,
                                                    scheduleDelay: plan.logDelay)
            logProcessors = [processor]
            batch = processor
        }
        logProcessor = batch
        let loggerProvider = LoggerProviderSdk(resource: resource, logRecordProcessors: logProcessors)
        logger = loggerProvider.get(instrumentationScopeName: Self.scope)

        let tracerBuilder = TracerProviderBuilder().with(resource: resource)
        if let url = plan.traces {
            let exporter = OtlpHttpTraceExporter(endpoint: url, config: config, envVarHeaders: none,
                                                 requeueOnFailure: false)
            let folder = queue.appendingPathComponent("traces")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = try? PersistenceSpanExporterDecorator(spanExporter: exporter, storageURL: folder,
                                                             performancePreset: Self.queuePreset)
            _ = tracerBuilder.add(spanProcessor: BatchSpanProcessor(spanExporter: kept ?? exporter,
                                                                    scheduleDelay: plan.spanDelay))
        }
        tracerProvider = tracerBuilder.build()
        tracer = tracerProvider.get(instrumentationName: Self.scope, instrumentationVersion: AppDelegate.version)

        if let url = plan.metrics {
            let exporter = OtlpHttpMetricExporter(
                endpoint: url, config: config,
                aggregationTemporalitySelector: plan.deltaMetrics ? AggregationTemporality.deltaPreferred()
                    : AggregationTemporality.alwaysCumulative(),
                envVarHeaders: none, requeueOnFailure: false)
            let folder = queue.appendingPathComponent("metrics")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = PersistenceMetricExporterDecorator(metricExporter: exporter, storageURL: folder,
                                                          performancePreset: Self.queuePreset)
            let reader = PeriodicMetricReaderBuilder(exporter: kept)
                .setInterval(timeInterval: plan.metricInterval)
                .build()
            let provider = MeterProviderSdk.builder()
                .setResource(resource: resource)
                .registerMetricReader(reader: reader)
                .build()
            meterProvider = provider
            meter = provider.meterBuilder(name: Self.scope)
                .setInstrumentationVersion(instrumentationVersion: AppDelegate.version)
                .build()
        } else {
            meterProvider = nil
            meter = nil
        }

        // What the SDK says about itself: a collector that cannot be reached, a body that could
        // not be made. To the log at debug, and never back into telemetry.
        OpenTelemetry.registerFeedbackHandler { message in Log.debug("telemetry: \(message)") }
    }

    static let scope = "org.opensmartpen.app"

    /// The queue on disk: small files, at most 20 MB for each signal, nothing older than a week.
    /// The SDK's own preset keeps 512 MB and throws a file away after 18 hours, which is the
    /// wrong way round for an app that sends little and is offline for days.
    private static let queuePreset = PersistencePerformancePreset(
        maxFileSize: 1024 * 1024,
        maxDirectorySize: 20 * 1024 * 1024,
        maxFileAgeForWrite: 4.75,
        minFileAgeForRead: 4.75 + 0.5,
        maxFileAgeForRead: 7 * 24 * 60 * 60,
        maxObjectsInFile: 500,
        maxObjectSize: 256 * 1024,
        synchronousWrite: false,
        initialExportDelay: 5,
        defaultExportDelay: 5,
        minExportDelay: 1,
        maxExportDelay: 60,
        exportDelayChangeRate: 0.1)

    /// Where the queue is: the caches folder, which macOS may empty and no backup takes.
    static var queueLocation: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("org.opensmartpen.app/telemetry")
    }

    /// Delete what waits to be sent. For the moment a person turns telemetry off: what they
    /// turned off must not go out at the next start.
    static func emptyQueue() {
        try? FileManager.default.removeItem(at: queueLocation)
    }

    // MARK: TelemetrySink

    func record(_ event: TelemetryEvent, in span: TelemetrySpan?) {
        var attributes = event.attributes.mapValues(Self.value)
        attributes["session.id"] = .string(session)
        var builder = logger.logRecordBuilder()
            .setTimestamp(event.time)
            .setObservedTimestamp(Date())
            .setSeverity(Self.severity(event.level))
            .setAttributes(attributes)
            .setBody(.string(event.body ?? event.name ?? ""))
        if let name = event.name { builder = builder.setEventName(name) }
        // The work it happened in. A collector then shows the line beside the upload that wrote it.
        if let span = span as? OTelSpan { builder = builder.setSpanContext(span.span.context) }
        builder.emit()
    }

    func measure(_ metric: TelemetryMetric, _ value: Double, attributes: [String: TelemetryValue]) {
        guard let meter else { return }
        // One run of the app is not said on a metric: each run would be a series of its own.
        let attributes = attributes.mapValues(Self.value)
        instruments.lock(); defer { instruments.unlock() }
        switch metric.kind {
        case .counter:
            let counter = counters[metric.name] ?? meter.counterBuilder(name: metric.name)
                .setUnit(metric.unit).setDescription(metric.description).build()
            counter.add(value: Int(value.rounded()), attributes: attributes)
            counters[metric.name] = counter
        case .histogram:
            let histogram = histograms[metric.name] ?? meter.histogramBuilder(name: metric.name)
                .setUnit(metric.unit).setDescription(metric.description)
                .setExplicitBucketBoundariesAdvice(TelemetryMetric.secondsBuckets).build()
            histogram.record(value: value, attributes: attributes)
            histograms[metric.name] = histogram
        case .gauge:
            let gauge = gauges[metric.name] ?? meter.gaugeBuilder(name: metric.name)
                .setUnit(metric.unit).setDescription(metric.description).build()
            gauge.record(value: value, attributes: attributes)
            gauges[metric.name] = gauge
        }
    }

    func begin(_ name: String, attributes: [String: TelemetryValue], parent: TelemetrySpan?) -> TelemetrySpan {
        let builder = tracer.spanBuilder(spanName: name)
        // Always said, one way or the other. Left unsaid, the SDK looks for a span that is
        // "active" on this thread, and this app keeps its own account of that.
        if let parent = parent as? OTelSpan { builder.setParent(parent.span) } else { builder.setNoParent() }
        for (key, value) in attributes { builder.setAttribute(key: key, value: Self.value(value)) }
        builder.setAttribute(key: "session.id", value: session)
        return OTelSpan(builder.startSpan())
    }

    /// Send what has gathered, now. Before the app stops.
    func flush(timeout: TimeInterval = 2) {
        logProcessor?.forceFlush(timeout: timeout)
        tracerProvider.forceFlush(timeout: timeout)
        _ = meterProvider?.forceFlush()
    }

    func shutdown() {
        _ = logProcessor?.shutdown(explicitTimeout: 2)
        tracerProvider.shutdown()
        _ = meterProvider?.shutdown()
    }

    private static func value(_ value: TelemetryValue) -> AttributeValue {
        switch value {
        case let .string(text): return .string(text)
        case let .int(number): return .int(number)
        case let .double(number): return .double(number)
        case let .bool(flag): return .bool(flag)
        }
    }

    private static func severity(_ level: TelemetryLevel) -> Severity {
        switch level {
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        case .fatal: return .fatal
        }
    }

    // MARK: who is reporting

    /// What every event and span says about where it comes from: the app and its version, the
    /// install, the system. No name of the Mac, no name of the account.
    static func resource(plan: TelemetryPlan, installId: String) -> Resource {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var attributes: [String: AttributeValue] = [
            "service.name": .string(plan.serviceName),
            "service.namespace": .string(TelemetryPlan.serviceNamespace),
            "service.version": .string(AppDelegate.version),
            "service.instance.id": .string(installId),
            // A packaged app is what people run. A bare binary is somebody working on the app.
            "deployment.environment.name": .string(Bundle.main.bundlePath.hasSuffix(".app") ? "production" : "development"),
            "os.type": .string("darwin"),
            "os.name": .string("macOS"),
            "os.version": .string("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"),
            "host.arch": .string(architecture),
        ]
        if let model = hardwareModel { attributes["device.model.identifier"] = .string(model) }
        // What the environment says replaces what the app says, as the specification has it.
        for (key, value) in plan.resource { attributes[key] = .string(value) }
        return Resource().merging(other: Resource(attributes: attributes))
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    /// The kind of Mac, as `Mac14,2`. A model, not a serial number.
    private static var hardwareModel: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

private final class OTelSpan: TelemetrySpan {
    var span: any Span

    init(_ span: Span) { self.span = span }

    func set(_ key: String, _ value: TelemetryValue) {
        switch value {
        case let .string(text): span.setAttribute(key: key, value: text)
        case let .int(number): span.setAttribute(key: key, value: number)
        case let .double(number): span.setAttribute(key: key, value: number)
        case let .bool(flag): span.setAttribute(key: key, value: flag)
        }
    }

    func end(error: String?) {
        if let error { span.status = .error(description: error) }
        span.end()
    }
}
