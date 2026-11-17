# Telemetry

The app can report to its makers how it is used and what goes wrong. This page is the full list of what it sends, when, and how to turn it off. If the code sends something that is not on this page, that is a bug.

Decided 2026-11-17; see `docs/decisions.md`.

## The short version

- **It is on unless you turn it off.** Settings → General → "Send usage data and error reports", or `"telemetry": {"enabled": false}` in the config.
- **You are told first.** At the first start that would send something, a window says so and has a "Turn Off" button. Nothing is sent until you answer it. If you turn it off there, what was collected until then is deleted and never sent.
- **This version sends nothing by default.** The project has no collector yet, so the address built into the app is empty. Telemetry only runs when a collector is named in the config or in the environment.
- **Off means off.** No environment variable turns it back on, and what was waiting to be sent is deleted.

## What is never sent

- What you write: no stroke, no dot, no page picture, no photo.
- The text of a page, from any agent.
- The title of a notebook, and the name you gave a pen.
- The name of a file or a folder of yours.
- Your bucket: its name, its address, the folder in it, the keys.
- The name of your Mac and the name of your account.
- The name of an agent. Only how many there are.

## What is sent with everything

Each event and span carries this, as OpenTelemetry resource attributes:

| Attribute | Value |
| --- | --- |
| `service.name`, `service.namespace` | `opensmartpen-mac`, `opensmartpen` |
| `service.version` | The app version, for example `0.2.0` |
| `service.instance.id` | The install id (see below) |
| `deployment.environment.name` | `production` for a packaged app, `development` for a bare binary |
| `os.type`, `os.name`, `os.version` | `darwin`, `macOS`, for example `15.1.0` |
| `host.arch` | `arm64` or `amd64` |
| `device.model.identifier` | The kind of Mac, for example `Mac14,2`. Not a serial number |
| `telemetry.sdk.*` | The name and version of the OpenTelemetry SDK |

Each event and span also has a `session.id`: a random id for one run of the app.

The collector also sees the internet address the request came from, as every server does.

### The install id

A random id, made at the first start and kept in `~/.config/opensmartpen/telemetry.json`. It is not made from the Mac, the account or a pen. It stays the same when the app is deleted and installed again, because that file is outside the app. Delete the file to get a new id. Settings → General shows the id, so you can give it to us when you report a problem.

### Pen addresses

Events about a pen carry its Bluetooth address (`pen.mac`), as it is. This is how the makers find the pens they gave away. Only a pen that this Mac paired with, or was connecting to because you were adding it, is ever named. A pen of somebody else that is only seen nearby is never reported.

`pen.model` is the name the pen gives itself over Bluetooth, for example `LAMY_safari`. It is not the name you gave the pen.

## Events

An event is an OpenTelemetry log record with an event name.

### The app

| Event | When | Attributes |
| --- | --- | --- |
| `app.start` | The app started | `pens.paired`, `pens.connected`, `bucket.connected`, `agents.count`, `books.count`, `pages.pending`, `app.uptime_seconds`, `app.launch` (`launchagent`, `bundle`, `binary`), `app.start_at_login`, `sync.quiet_seconds`, `pen.free_memory_after_sync`, `install.age_days` |
| `app.heartbeat` | Every 6 hours while the app runs | The first seven attributes of `app.start` |
| `app.stop` | The app was quit | The same seven |
| `app.crash` | At the next start after a crash | `exception.type`, `exception.message`, `exception.stacktrace`, `crash.incident_id`, `crash.app_version`, `crash.os_version`, `crash.binary_uuid` |
| `system.sleep`, `system.wake` | The Mac went to sleep or woke | `pens.connected` (sleep only) |
| `notice.posted` | The app showed a notification | `notice.key` (for example `battery`, `publish-failed`), `pen.mac` when it is about a pen. Not the words of the notification |

A crash is read from the report that macOS writes in `~/Library/Logs/DiagnosticReports`. The app reads only its own reports, and only those written after telemetry was first set up. From a report it takes the kind of crash, what the system said about it, and the thread that crashed, with the names of the binaries and no paths. At most five reports are sent at one start.

### Pens

| Event | When | Attributes |
| --- | --- | --- |
| `pen.paired` | A new pen was paired | `pen.mac`, `pen.pairing` (`first pen`, `added`), `pens.paired` |
| `pen.connected` | A pen connected and accepted the app | `pen.mac`, `pen.model`, `pen.firmware`, `pen.link_seconds` |
| `pen.status` | The first report of a pen after it connects | `pen.mac`, `pen.battery`, `pen.charging`, `pen.memory_used`, `pen.auto_off_minutes`, `pen.offline_save` |
| `pen.offline_memory` | The pen said what is in its memory | `pen.mac`, `drain.books` |
| `pen.disconnected` | A pen went away | `pen.mac`, `pen.connected_seconds`, `pen.disconnect_error`, `pen.disconnect_reason` (`sleep`) |
| `pen.powered_off` | The pen said it is switching off | `pen.mac`, `pen.power_off_reason` |
| `pen.forgotten` | A pen was removed in Settings | `pen.mac`, `pens.paired` |
| `pen.rejected` | A pen that is not paired connected and was let go | None |
| `pen.add_timed_out` | "Add Pen…" found no pen in two minutes | None |
| `bluetooth.unavailable` | Bluetooth is off or not allowed | `bluetooth.authorization` |
| `control.tap` | A tap on the paper control strip | `control.button` (for example `ink red`, `width thin`, `no button`) |

### Pages and notebooks

| Event | When | Attributes |
| --- | --- | --- |
| `book.added` | A notebook was seen for the first time, or a new copy began | `book.surface` (the code printed on the paper, for example `s3/o27/b450`: a product, not your notebook), `book.known`, `book.copies`, `book.copy_signal` |
| `photo.added` | A photo was filed as a page | `photo.source` (`file`, `drop`, `sample`, `device`), `photo.format`, `photo.bytes` |
| `photo.rejected` | A file could not be added as a photo | `photo.source`, `photo.reason` |
| `sync.recovered` | Unsent pages were found at the start | `sync.pages` |
| `agents.changed` | The number of agents changed | `agents.count`, `agents.behind` |
| `transcript.looked_up` | The viewer asked for the text of a page, once for each page shown | `transcript.state` (`text`, `none`, `unavailable`) |

### The bucket

| Event | When | Attributes |
| --- | --- | --- |
| `bucket.connect` | "Connect" was clicked in Settings → Sync | `bucket.result` (`connected`, `refused`, `unreachable`, `incomplete`, `secret not saved`), `bucket.service` (`aws`, `other`), `bucket.has_folder`, `http.response.status_code`, `bucket.error_code` (the service's own code, for example `AccessDenied`) |
| `bucket.disconnected` | The bucket was disconnected | None |

### Clicks

| Event | When | Attributes |
| --- | --- | --- |
| `ui.panel.opened` | The menu bar panel was opened | None |
| `ui.panel.pinned`, `ui.panel.unpinned` | The panel was put in its own window, or taken out | None |
| `ui.panel.pen_opened` | A pen in the panel was opened | None |
| `ui.ink.chosen`, `ui.width.chosen` | An ink or a width was chosen in the panel | `ink.color` or `ink.width`, `ink.target` (`writing now`, `pen default`) |
| `ui.viewer.opened` | The viewer was opened | `viewer.target` (`page`, `latest`) |
| `ui.viewer.transcript` | The transcript pane was opened or closed | `transcript.shown` |
| `ui.photo.menu` | "Add Photo…" was clicked | None |
| `ui.agent.copy_instructions` | "Copy instructions" was clicked | `ui.source` (`panel`, `settings`) |
| `ui.agent.opened` | An agent's link was opened | None |
| `ui.sync_now` | A sync was asked for by hand | `ui.source` |
| `ui.notes.opened`, `ui.log.opened` | The notes folder or the log was opened | `ui.source` |
| `ui.settings.opened` | The settings window was opened | None |
| `ui.settings.tab` | A tab of the settings window came on screen | `settings.tab` |
| `ui.setting.changed` | A setting was changed | `setting.name`, `setting.value`. For: `startAtLogin`, `quietSeconds`, `deleteFromPenAfterPublish`, `lowBatteryPercent`, `memoryWarnPercent`, and `telemetry` when it is turned on |
| `ui.pen.add`, `ui.pen.add_cancelled` | "Add Pen…" or its "Cancel" was clicked | None |
| `ui.pen.forget` | "Remove" was confirmed for a pen | `pen.mac` |
| `ui.pen.edited` | A pen was changed in Settings | `pen.mac`, and what changed: `pen.renamed` (only that it was), `pen.mode`, `pen.ink`, `pen.width` |
| `ui.book.renamed` | A notebook got a new title | `book.surface`. Not the title |
| `ui.quit` | ⌘Q in the panel | None |

Turning telemetry off is not reported. Off means that nothing more is sent.

## Spans

A span is work with a start, an end and a result.

| Span | What | Attributes |
| --- | --- | --- |
| `pen.connect` | The Bluetooth link to a pen, from the first call to the link | `pen.mac`, `pen.paired` |
| `pen.drain` | One notebook leaving pen memory, to the upload and the delete from the pen | `pen.mac`, `book.surface`, `drain.strokes`, `drain.pages` |
| `sync.publish` | One upload of the waiting pages | `sync.reason` (`quiet`, `manual`, `photo`, `drain`, `other`), `sync.pages`, `sync.files`, `sync.failures_before`, `strokes.live`, `strokes.offline` (how many strokes were written since the last upload, as numbers) |
| `pages.draw` | Inside `sync.publish`: the page pictures are drawn | `pages.drawn`, `pages.changed` |
| `s3.upload` | Inside `sync.publish`: the files go to the bucket. Only with a bucket | `s3.files` |
| `s3.put` | Inside `s3.upload`: one file | `file.kind` (`strokes`, `picture`, `photo`, `book`, `pen`, `mode`, `palette`, `time`), `file.size`. Not the name of the file |

A span that failed carries the error as its status.

## Warnings and errors from the log

Each line that the app writes to its log at the level WARN or ERROR is also sent, as a log record with the words of the line and no event name. These lines are how a bug is found.

Before any text leaves the Mac, the app cleans it. This applies to every string in every event and span:

- The path of your home folder becomes `~`.
- The bucket's name, the folder in it, the key id and the address of the service become `<bucket>`, `<folder>`, `<key-id>` and `<endpoint>`. A word of fewer than three letters is not replaced.
- A notes folder that is outside your home folder becomes `<notes>`.
- The name of a pen's file, which is made from the name you gave the pen, becomes `pens/<pen>.json`.
- Text longer than 8,000 characters is cut.

An error message that comes from macOS or from the bucket service is sent after this cleaning. The cleaning is a net, not a proof: if you find private text in what is sent, report it as a bug.

Two lines of the log name a file of yours (a file that could not be added as a photo). They stay in the log on the Mac, and telemetry gets `photo.rejected` in their place. The words of a notification stay on the Mac too.

For a developer: a WARN or ERROR line must not carry a name that a person gave to something. A line that must carry one is written as `Log.warn("…", telemetry: false)`.

## Where it goes, and how

The app uses the OpenTelemetry SDK for Swift and sends OTLP over HTTP with protobuf, to `<endpoint>/v1/logs` and `<endpoint>/v1/traces`. There are no metrics: the counts can be made from the events.

What is to be sent is written to `~/Library/Caches/org.opensmartpen.app/telemetry` first and sent from there, so events from a time without network are sent later. The queue holds at most 20 MB for each signal and nothing older than one week. It is deleted when telemetry is turned off.

The address comes from three places. The first one that is set is used:

1. The standard OpenTelemetry environment variables.
2. `telemetry` in `~/.config/opensmartpen/config.json`.
3. The address built into the app, which is empty in this version.

```json
"telemetry": {
  "enabled": true,
  "endpoint": "http://localhost:4318",
  "headers": { "authorization": "a-key" }
}
```

The app reads these environment variables:

| Variable | Meaning |
| --- | --- |
| `OTEL_SDK_DISABLED` | `true` turns telemetry off |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | The collector. `/v1/logs` and `/v1/traces` are added to it |
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | The whole address for one signal, used as it is |
| `OTEL_EXPORTER_OTLP_HEADERS` | `key=value,key=value`. Added to the headers from the config, and wins over them |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | Milliseconds. The default is 10000 |
| `OTEL_EXPORTER_OTLP_COMPRESSION` | `gzip` (the default) or `none` |
| `OTEL_LOGS_EXPORTER`, `OTEL_TRACES_EXPORTER` | `none` turns one signal off |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | Replace the app's own values |
| `OTEL_BLRP_SCHEDULE_DELAY`, `OTEL_BSP_SCHEDULE_DELAY` | Milliseconds between two exports. The default is 5000 |

`OTEL_EXPORTER_OTLP_PROTOCOL` is read, but only `http/protobuf` is supported. Other variables are not read.

An app started by the LaunchAgent or at login does not see the variables of your shell. For that app, use the config file. The variables work for a binary started from a terminal.

A variable cannot turn telemetry on for a person who turned it off.

## To see it work

1. Start a collector that takes OTLP over HTTP on port 4318.
2. Put `"telemetry": {"enabled": true, "endpoint": "http://localhost:4318"}` in the config and start the app.
3. Answer the notice. The events of the start arrive some seconds later: they wait in the queue on disk for about five seconds first.
