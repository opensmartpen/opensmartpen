# Open Smart Pen

macOS menubar app that keeps a smartpen's strokes flowing into `~/OpenSmartPen` with no attention from the user. The notes sit outside the app, so deleting it and installing it again costs nothing. Soon after the pen stops, each page gets a PNG beside its strokes. Connect an S3 bucket in Settings → Sync and both files are copied there; with no bucket connected the notes stay on this Mac. It does not transcribe anything and runs no agents: whatever reads the folder or the bucket does that.

## What it does

- Accepts several pens, all connected at once. A pen is added with "Add Pen", in the panel while no pen is paired and in Settings → Pens after that; the app then takes the next pen that is switched on near the Mac. With no pen paired and none being added, the app does not scan, so macOS asks about Bluetooth only at "Add Pen". "Forget…" on a pen stops syncing from it and keeps its record, because the strokes it wrote still name it.
- Scans whenever a paired pen is not connected, and connects one pen at a time. Each connected pen authorises, drains and streams on its own.
- On connect, per pen: authorises (sends the configured PIN once if the pen asks), sets the pen clock, subscribes to all notebooks, then drains offline memory one notebook at a time.
- Live strokes are appended to `books/<copy>/raw/p{page}.jsonl` as they finish. Each physical copy of a notebook is one folder (ADR-002).
- Pages are finished once no pen has reported any event for `quietSeconds`. Each page is then drawn as a PNG, and with a bucket both files go up. `../docs/processing.md` has the layout, the order and the timing.
- Offline strokes are uploaded as soon as a notebook has been fully transferred. Only after the upload succeeds is that notebook deleted from the pen.
- Failures are retried with backoff and surfaced as macOS notifications after three attempts. Battery, memory, PIN, duplicate connection and stalled transfers also notify. Normal operation is silent.

## The menubar panel

The menubar item is a pencil, in every state — an icon that turns into a battery symbol when the battery is low disappears exactly when you go looking for it. A drop of ink beside the pencil means pages are written but not yet uploaded; the pencil goes red with a percentage below `lowBatteryPercent`, and dims when no pen is connected.

Clicking it opens a SwiftUI panel (`NSPopover`, 252 pt) that answers one question: is my writing safe?
The width is cut to three pen tiles and the pin and no more — three is as many pens as are plausibly
in use at once, and a panel sized for a fourth is too wide every day for a case that never arrives.

- **Every waiting page, counted down.** Each pending page is listed with the time left in its quiet window, so the wait is visible instead of invisible. The page being written right now has no countdown — its timer restarts on every stroke — and carries a live dot instead.
- **Pages are named, not numbered in Ncode.** Each copy's `book.json` carries the name the person uses. Ncode page numbers are not the printed ones (the LAMY pad's first written sheet reported as page 4), so a page number is shown only for a notebook whose `first_page` has been calibrated; otherwise just the name.
- **Battery is a gauge; pen memory is not.** Battery is a level — always relevant, fixed by charging. Pen memory is a backlog: normally zero, only filling when you write away from this Mac, and it empties itself on connect. It gets a line of prose under the battery when there is something to say, and a progress bar while a transfer is running.
- **Failures lead with the reassurance.** When an upload keeps failing the panel says how many pages are safe on disk before it says anything about the bucket.
- Colour only appears when it means something: violet for work in flight, amber for something to know, red for something to fix. The resting state has no colour at all.

## Build and run

Requires Xcode with Swift 6.4 on macOS 13+. Depends on NeoLAB's `NISDK3` (GPL-3.0) via SwiftPM, pinned to tag 1.1.5, and on the OpenTelemetry SDK for Swift (Apache-2.0), 2.6.0.

The Swift version comes from the OpenTelemetry SDK. The SDK itself needs Swift 6.0, and `Package.resolved` was made with Swift 6.4: some of the packages it pins say they need 6.2 or 6.4. With an older toolchain, `swift package update` should find versions that fit; nobody tested that. The first build downloads about 25 packages, because the SDK's package names its gRPC exporter too. Only the HTTP exporter, `swift-protobuf` and `swift-log` are compiled into the app.

The command line tools without Xcode build `OpenSmartPenCore` and nothing else: they have no plugin for SwiftUI's `@State` and no XCTest.

```sh
cd app
swift test                         # core logic, no hardware needed
scripts/make-signing-identity.sh   # once per Mac: a certificate, so rebuilds keep their grants
scripts/make-app.sh                # dist/"Open Smart Pen.app", signed with it (ad hoc without it)
scripts/install-launchagent.sh     # start at login, restart on exit
scripts/fresh.sh [app]             # run a build as a new person sees it, apart from the real app
```

The first time, run the installer from a terminal and stay with it: it opens the app once from the
Finder so macOS raises the Bluetooth prompt, waits for you to allow it, and only then hands over to
the LaunchAgent. That order is not cosmetic — see [Bluetooth permission](#bluetooth-permission).
After that, a build signed with the same certificate is installed and started with nobody watching.

The app keeps its log in `~/Library/Logs/OpenSmartPen/opensmartpen.log`, however it was started. At 2 MB the file becomes `opensmartpen.1.log` and a new one starts, so the log is never more than about 4 MB.

Running the bare binary with `swift run` also works for debugging (stderr log, AppleScript notifications), but Bluetooth permission is then attributed to the terminal and macOS notifications are unavailable. Set `OPENSMARTPEN_VERBOSE=1` for debug logging.

### A release

```sh
scripts/package.sh                 # release/OpenSmartPen-<version>.dmg, .zip and appcast.xml
OPENSMARTPEN_TEAM_ID=<team> scripts/verify-release.sh   # refuses a build Gatekeeper will not open
```

Without the Apple credentials the build is unsigned, and `verify-release.sh` refuses it. The
names of the credentials are at the top of `scripts/package.sh`.

A public release is made by GitHub, not on a Mac: set `AppDelegate.version`, merge, and push the
tag `v<version>`. The workflow `.github/workflows/release.yml` packages, verifies, and makes a
draft release with the files. Read the draft and publish it. An installed release finds the new
one by itself, from `appcast.xml` of the newest published release.

### Bluetooth permission

macOS offers the Bluetooth prompt **only to an app launched from the Finder**. One started by
launchd is never asked: `CBCentralManager.authorization` stays `notDetermined`, and the app sits
reporting that it is waiting — for a radio that is already switched on.

Two consequences worth knowing before you go looking for a bug:

- `open` on a bundle that is already running just activates the running copy. It starts no process
  and raises no prompt, so the Finder launch has to come *before* the agent is bootstrapped. The
  installer does it in that order.
- The grant is keyed to the **code signature** as well as the bundle id. An ad-hoc signature is
  the binary's own hash, so it changes with every build: permission is lost on a rename *and* on a
  plain rebuild. `scripts/make-signing-identity.sh` makes a self-signed certificate in the login
  keychain, once; `make-app.sh` signs with it from then on, and the signature then says "this
  bundle id, this certificate" about every build. `install-launchagent.sh` compares what the old
  and the new bundle's signatures say, and skips the Finder step when they agree.
  `OPENSMARTPEN_ASK=1` makes it ask anyway.

`PenSession.bluetoothProblem()` reads the authorization state and says which of the two faults it
is, in the log and in a notification — "Bluetooth is off" and "we were never given permission" need
opposite fixes, and the menubar can only show the first.

## Working on the design

```
scripts/dev-design.sh
```

Opens a detached, always-visible window showing the panel in both appearances at once, with a
picker for every state it can be in, and rebuilds and reopens it whenever a source file changes.
The window keeps its position and its selected state across a rebuild, so the loop reads as a
reload.

This is a separate app, `opensmartpen-design`, not a mode of the one people install. It runs
nothing else — no pen, no bucket, no menubar item — so it is safe to run while the installed
LaunchAgent is running. `.build/debug/opensmartpen-design` opens the same window without the
rebuild loop.

The states come from `Scenario` in `Sources/OpenSmartPenDesign` rather than from hardware, because a
failing upload, a memory drain and a first run each take deliberate setup to see even once. No
fixture is reachable from the shipped app: nothing in it can import that target.

The panel gets a state through `PanelModel.Snapshot` — every published property as one value —
and the model itself carries no make-believe. The viewer has no design window yet; it is the one
part of the UI still worked on by running the whole app.

The settings window can be looked at the same way, on fixtures in a temporary folder:
`.build/debug/opensmartpen-design --settings=sync` opens it on a tab (`pens`, `books`, `sync`,
`general`, `about`), and adding `--bucket` shows it as it is once a bucket is connected.

### The app icon

`scripts/make-icon.swift` draws `Resources/AppIcon.icns`. It is the pencil from the menu bar: the
same path, on the same 16-unit grid, as `StatusIcon.pencil`. It is kept as code and not as a
picture in the repository, so the two cannot drift apart unnoticed. It has no ink drop: in the
menu bar the drop means that pages wait to be synced, and an icon must not claim a state.

The app icon is the same picture as `assets/logo.png`: a near-white plate with a violet and a pink
tint, and the pencil. Each size is drawn again, not scaled down. `make-app.sh` makes the `.icns`
again at each build, and it is not committed. `assets/logo.png` and `assets/avatar.png` are
committed, because the README and GitHub need a file; `--logo` and `--avatar` write them.

## Pens and notebooks

Both are recorded beside the notes, not in the app, because the renderer needs them too.

- `pens/<slug>.json` — name, mode (writing / highlight), default ink and width. A pen is
  adopted the first time it connects, so it has a name from the start rather than a MAC address.
- `books/<copy>/book.json` — surface identity, title, paper size, first page, when this copy began
  and which signal decided it. A notebook gets a record the moment a page arrives from it.
  Recognised products name themselves; anything else is named after its paper.

A book folder is named by the surface identity the pen reported and a six-character id we
generated: `books/s3-o27-b450-7f3a9c`. The id means nothing and never changes, so a title is free
to change without a single file moving. `book.json` is the only authority; nothing reads meaning
out of the folder name.

Two notebooks of the same model report the same Ncode id, so a second copy has to be worked out.
Open Smart Pen decides for itself and never asks: writing is not interrupted to put a question. New
strokes landing on ink already on the sheet decides it alone; ink appearing at the front of a book
already written well past it, after a silence, decides it with that silence; a silence on its own
decides nothing. When the signals disagree the answer is the new copy — a wrong split is a second
book you can see and repair by moving pages, while a wrong merge interleaves two notebooks inside
one captured file and could only be repaired by cutting it.

## Configuration

`~/.config/opensmartpen/config.json`, created with defaults on first launch. Missing keys keep their defaults.

| Key | Default | Meaning |
|---|---|---|
| `dataPath` | `~/OpenSmartPen` | Where the notes are kept. |
| `quietSeconds` | `30` | Seconds with no event from any pen before the waiting pages are uploaded. |
| `s3` | none | The bucket: `bucket`, `region`, `accessKeyId`, and optionally `prefix` (a folder in the bucket) and `endpoint` (for a service other than Amazon S3). Set in Settings → Sync, which tests the connection before saving it. The secret key is not here: it is in `s3-secret` beside this file, mode 0600. |
| `pairedPens` | none | The pens this Mac accepts, each with its Bluetooth address and the identifier macOS gave it. A pen that has connected before must agree in both. Add a pen with "Add Pen"; remove one in Settings → Pens. |
| `startAtLogin` | `true` | Start the app when you log in. Set in Settings → General. |
| `penPassword` | none | PIN for a locked pen. Sent once per connection; never retried, because repeated wrong PINs factory-reset the pen. |
| `deleteFromPenAfterPublish` | `true` | Free pen memory once a notebook is synced: uploaded when a bucket is connected, on this Mac's disk when none is. |
| `lowBatteryPercent` | `20` | Notify at or below this level when not charging. |
| `memoryWarnPercent` | `70` | Notify when pen memory usage reaches this level. |
| `controlBooks` | `["s3/o1013/b1"]` | Printed control surfaces rather than paper to write on. Taps on them are kept as evidence and decoded as settings, but they are never pages. |
| `sdkDebugLog` | `false` | Print the SDK's protocol log. |
| `hiddenBooks` | none | Notebooks that the panel does not list, by folder name. Set with "Show in panel" in Settings → Notebooks. |
| `telemetry` | see the link | What the app reports to its makers: `enabled`, and optionally `endpoint` (the collector) and `headers`. `../docs/telemetry.md` says when it is on and where it goes. |

## The bucket

The layout of the bucket is the layout of the notes folder, under `prefix` if one is set.
`../docs/processing.md` has it, with the order of the uploads and what an agent watches.

A key that is only allowed `s3:PutObject` on the bucket is enough to upload: the app never lists,
and a sync never deletes. To show a transcript in the viewer the key needs `s3:GetObject` too, and
to delete a notebook or remove an agent in Settings it needs `s3:DeleteObject`.

A PNG that is missing or older than its strokes is drawn again at the next start.

What has been uploaded is remembered in `~/.config/opensmartpen/s3-uploaded.json`, by file size and
date, for one bucket. Connect a different bucket — or delete that file — and everything on disk is
uploaded again. Connecting tests the keys, the bucket and the region, and writes nothing: it asks
for a file that does not exist and reads how the bucket says no. It does not prove that the key may
write; a key that may not shows at the first upload, as a notification.

## Transcripts

The app does not transcribe. The viewer shows the text an agent wrote, beside the ink: the button
in its bar, or T. `../docs/processing.md` says where an agent puts that text and how the app
fetches it.

In the viewer, ⌘+ and ⌘− zoom, ⌘0 shows the whole page again, and scroll or pinch zooms about the
pointer. While a zoom is moving the page is stretched, and it is redrawn sharp when it stops.

## Telemetry

The app reports how it is used and what goes wrong, with the OpenTelemetry SDK, as OTLP over HTTP: events and log lines to `/v1/logs`, spans to `/v1/traces`, metrics to `/v1/metrics`. `../docs/telemetry.md` is the list of everything that is sent and of the `OTEL_*` variables the app reads.

- **The first window** is `TelemetryNoticeController`, and `TelemetryPlan.questionIsOwed` says when it is owed. `opensmartpen-design --notice` shows it. What it does for telemetry is in `../docs/telemetry.md`.
- **To test against a local collector:** start one on port 4318 and put `"telemetry": {"enabled": true, "endpoint": "http://localhost:4318"}` in the config. `../docs/telemetry.md` has the command for a collector in a container. The installed app is started by launchd and does not see the variables of a shell; a binary started from a terminal does.
- **In the code:** `Telemetry` in `OpenSmartPenCore` is what every layer calls (`Telemetry.event`, `Telemetry.span`, `Telemetry.count`, `Telemetry.measure`). Every span is also measured as `opensmartpen.operation.duration`, so new timed work needs no metric of its own. It knows nothing of OpenTelemetry. `OTelTelemetry` in the app target is the only file that imports the SDK. A line written with `Log.warn` or `Log.error` is sent too, so it must not carry a name a person gave to something; `telemetry: false` keeps a line on the Mac.
- **Files:** `~/.config/opensmartpen/telemetry.json` holds the install id and whether the person was told. `~/Library/Caches/org.opensmartpen.app/telemetry` is the queue of what is not sent yet.

## Layout

Four layers, each unable to reach the one above it.

- `Sources/OpenSmartPenCore` — no SDK dependency, no AppKit, fully unit-tested: models and JSONL serialisation, `StrokeAssembler` (dots → strokes), `RawStore` (append-only files), `QuietTracker` (what is pending and when it publishes), `Notebook`/`PageNaming` (how a page is described to a person), `S3Client` and `SigV4` (put a file in a bucket, with no AWS SDK), `PagePictures` (the PNG of each page, kept in the folder), `S3Sync` (what has been uploaded and what has not), `SyncCoordinator` (write, track, upload, back off, notify), `Config`, notifiers, `Telemetry` (what the app reports, with no SDK behind it), `TelemetryPlan` (where it goes), `CrashReport` (a crash, read from the report macOS wrote).
- `Sources/OpenSmartPenUI` — every window and view, and no SDK: `PanelModel` (one observable snapshot fed by the existing `onChange` closures), `StatusPanel` (SwiftUI), `StatusIcon` (the pencil and its states), `Viewer`, the pinned and menubar panels, the settings window. `PenLink` is the whole of what it knows about a pen — a protocol of plain values, so the layer builds and runs with no pen and no SDK linked in.
- `Sources/OpenSmartPen` — the app: `PenSession` (NISDK3 delegates, connection and drain state machine, and the only conformance to `PenLink`), `SDKMapping`, `AppDelegate` (status item and popover), `UserNotifier`, `OTelTelemetry` (the OpenTelemetry SDK, and the only file that imports it).
- `Sources/OpenSmartPenDesign` + `Sources/OpenSmartPenDesignApp` — the design window and its fixtures, and the `opensmartpen-design` executable that opens it. Nothing else imports these, so none of it ships.
- `Tests/OpenSmartPenCoreTests` — the bucket is a dictionary in these, so the suite needs no network. `S3Tests` checks the signing against the worked example in the AWS documentation, and has one test that writes to a real bucket when `OPENSMARTPEN_TEST_S3_BUCKET` (and `_KEY_ID`, `_SECRET`, optionally `_REGION` and `_ENDPOINT`) are set.
