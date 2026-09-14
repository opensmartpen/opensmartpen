# Brainio Pen

macOS menubar app that keeps a Neo smartpen's strokes flowing into `~/Brainio/pen` with no attention from the user. The notes sit outside the app, so deleting it and installing it again costs nothing. Nothing leaves the Mac: a git repository over the same directory is a record of what changed, not a backup — give it an `origin` and turn `gitPush` on if you later want the notes copied somewhere. It does not render or transcribe anything; that is the processing side's job (see `../docs/processing.md`).

## What it does

- Scans for the pen whenever none is connected. The first pen ever seen is paired and remembered; after that only that pen is accepted.
- On connect: authorises (sends the configured PIN once if the pen asks), sets the pen clock, subscribes to all notebooks, then drains offline memory one notebook at a time.
- Live strokes are appended to `books/<copy>/raw/p{page}.jsonl` as they finish. Each physical copy of a notebook is one folder (ADR-002).
- A page is published when it has been quiet for `quietMinutes` (default 10): its file is committed. Only quiet pages are committed, so a half-written page never lands in git.
- Offline strokes are published as soon as a notebook has been fully transferred. Only after the commit succeeds is that notebook deleted from the pen.
- Failures are retried with backoff and surfaced as macOS notifications after three attempts. Battery, memory, PIN, duplicate connection and stalled transfers also notify. Normal operation is silent.

## The menubar panel

The menubar item is a pencil, in every state — an icon that turns into a battery symbol when the battery is low disappears exactly when you go looking for it. A drop of ink beside the pencil means pages are written but not yet committed; the pencil goes red with a percentage below `lowBatteryPercent`, and dims when no pen is connected.

Clicking it opens a SwiftUI panel (`NSPopover`, 252 pt) that answers one question: is my writing safe?
The width is cut to three pen tiles and the pin and no more — three is as many pens as are plausibly
in use at once, and a panel sized for a fourth is too wide every day for a case that never arrives.

- **Every waiting page, counted down.** Each pending page is listed with the time left in its quiet window, so the ten-minute wait is visible instead of invisible. The page being written right now has no countdown — its timer restarts on every stroke — and carries a live dot instead.
- **Pages are named, not numbered in Ncode.** Each copy's `book.json` carries the name the person uses. Ncode page numbers are not the printed ones (the LAMY pad's first written sheet reported as page 4), so a page number is shown only for a notebook whose `first_page` has been calibrated; otherwise just the name.
- **Battery is a gauge; pen memory is not.** Battery is a level — always relevant, fixed by charging. Pen memory is a backlog: normally zero, only filling when you write away from this Mac, and it empties itself on connect. It gets a line of prose under the battery when there is something to say, and a progress bar while a transfer is running.
- **Failures lead with the reassurance.** When a commit keeps failing the panel says how many pages are safe on disk before it says anything about git.
- Colour only appears when it means something: violet for work in flight, amber for something to know, red for something to fix. The resting state has no colour at all.

## Build and run

Requires Xcode 15+ (Swift 5.9) on macOS 13+. Depends on NeoLAB's `NISDK3` (GPL-3.0) via SwiftPM, pinned to tag 1.1.5.

```sh
cd app
swift test                         # core logic, no hardware needed
scripts/make-app.sh                # dist/"Brainio Pen.app", ad-hoc signed
scripts/install-launchagent.sh     # start at login, restart on exit, logs in ~/Library/Logs/BrainioPen
```

Run the installer from a terminal and stay with it: it opens the app once from the Finder so macOS
raises the Bluetooth prompt, waits for you to allow it, and only then hands over to the LaunchAgent.
That order is not cosmetic — see [Bluetooth permission](#bluetooth-permission).

Running the bare binary with `swift run` also works for debugging (stderr log, AppleScript notifications), but Bluetooth permission is then attributed to the terminal and macOS notifications are unavailable. Set `BRAINIO_PEN_VERBOSE=1` for debug logging.

### Bluetooth permission

macOS offers the Bluetooth prompt **only to an app launched from the Finder**. One started by
launchd is never asked: `CBCentralManager.authorization` stays `notDetermined`, and the app sits
reporting that it is waiting — for a radio that is already switched on.

Two consequences worth knowing before you go looking for a bug:

- `open` on a bundle that is already running just activates the running copy. It starts no process
  and raises no prompt, so the Finder launch has to come *before* the agent is bootstrapped. The
  installer does it in that order.
- The grant is keyed to the **code signature** as well as the bundle id, and an ad-hoc signature
  changes with every build. So permission is lost on a rename *and* on a plain rebuild, and
  `install-launchagent.sh` asks for it again each time. A Developer ID would fix this; ad-hoc
  signing is the price of not having one.

`PenSession.bluetoothProblem()` reads the authorization state and says which of the two faults it
is, in the log and in a notification — "Bluetooth is off" and "we were never given permission" need
opposite fixes, and the menubar can only show the first.

## Moving from PenBridge

The app was called PenBridge until 2026-09-12. One script does the whole switch, and shows what it
would do before it does anything:

```sh
scripts/migrate-from-penbridge.sh            # dry run
scripts/migrate-from-penbridge.sh --apply
```

It stops `com.apoco.penbridge` before moving anything — it writes to both the config directory and
the notes repo, and would otherwise be moved out from under itself — then moves
`~/.config/penbridge/` → `~/.config/brainio-pen/`, `~/PenBridge/notes` → `~/BrainioPen/notes` (with
`repoPath` following it), and the logs, before building and installing the new agent. Every step
checks whether it has already happened, so running it twice is safe, and it refuses to merge two
note histories if both paths exist.

`install-launchagent.sh` retires the old agent and deletes `~/Applications/PenBridge.app` on its
own too, so the two never run at once — two agents would both own the pen and both commit to the
notes repo.

Without the script, the app still looks after itself: on first launch it **copies** a
`~/.config/penbridge/` directory across, whole, so the paired pen, the PIN and the battery history
survive. The old directory is left alone, so an install still on the old name keeps working.

`repoPath` comes across too, and is then read once for a different purpose: ADR-002 moved the notes
to `~/Brainio/pen` in a layout of one folder per copy of a notebook, so whatever `repoPath` names is
**copied** into it on first launch. That old directory is also left exactly as it was — it is a git
repository holding the only copy of some strokes, and it is yours to delete once you have looked at
the new one.

The bundle id changed from `com.apoco.penbridge` to `com.brainio.pen`. macOS ties Bluetooth and
notification permission to the bundle id, so both are asked for once more; until Bluetooth is
granted the pen will not connect. Saved window positions reset for the same reason. The installer
walks you through the grant — see [Bluetooth permission](#bluetooth-permission) for why the order
matters.

One order to avoid: launching the new app *before* moving the old config across. That writes a
fresh defaults-only `config.json`, and the pen then looks unpaired even though its details are
still sitting in `~/.config/penbridge/`. Adoption fills in whatever is missing rather than
refusing, so a bare directory is fine, but an existing `config.json` is never overwritten — it
might be one you meant. The app warns on every launch when it finds itself running on pure
defaults with a PenBridge-era config still on disk, and says how to fix it.

## Working on the design

```
./dev-design.sh
```

Opens a detached, always-visible window showing the panel in both appearances at once, with a
picker for every state it can be in, and rebuilds and reopens it whenever a source file changes.
The window keeps its position and its selected state across a rebuild, so the loop reads as a
reload.

This is a separate app, `brainio-pen-design`, not a mode of the one people install. It runs
nothing else — no pen, no git, no menubar item — so it is safe to run while the installed
LaunchAgent is running. `.build/debug/brainio-pen-design` opens the same window without the
rebuild loop.

The states come from `Scenario` in `Sources/BrainioPenDesign` rather than from hardware, because a
failing push, a memory drain and a first run each take deliberate setup to see even once. No
fixture is reachable from the shipped app: nothing in it can import that target.

The panel gets a state through `PanelModel.Snapshot` — every published property as one value —
and the model itself carries no make-believe. The viewer has no design window yet; it is the one
part of the UI still worked on by running the whole app.

### The app icon

`scripts/make-icon.swift` draws `Resources/AppIcon.icns`. It is the notebook from the panel's book
rows — `PaperMark`, bound, with the ink dot on its corner — kept as code rather than as a
checked-in image so the two cannot drift apart unnoticed. A notebook rather than a pencil because a
pencil is what every note app puts on its icon and says nothing about this one; the elastic band is
what still reads as *this* notebook at 16 px.

`PaperMark`'s proportions are copied exactly and its stroke weight is not: a 1-in-11 line is right
at 13 pt and reads as a fat letter at 1024, so the glyph is drawn larger and lighter. Each size is
redrawn rather than downsampled, for the same reason. `make-app.sh` regenerates the `.icns` on
every build and it is not committed — derived, like everything else here.

## Pens and notebooks

Both are recorded beside the notes, not in the app, because the renderer needs them too.

- `pens/<slug>.json` — name, mode (writing / accent / highlight), default ink and width. A pen is
  adopted the first time it connects, so it has a name from the start rather than a MAC address.
- `books/<copy>/book.json` — surface identity, title, paper size, first page, when this copy began
  and which signal decided it. A notebook gets a record the moment a page arrives from it.
  Recognised products name themselves; anything else is named after its paper.

A book folder is named by the surface identity the pen reported and a six-character id we
generated: `books/s3-o27-b450-7f3a9c`. The id means nothing and never changes, so a title is free
to change without a single file moving. `book.json` is the only authority; nothing reads meaning
out of the folder name.

Two notebooks of the same model report the same Ncode id, so a second copy has to be worked out.
Brainio Pen decides for itself and never asks: writing is not interrupted to put a question. New
strokes landing on ink already on the sheet decides it alone; ink appearing at the front of a book
already written well past it, after a silence, decides it with that silence; a silence on its own
decides nothing. When the signals disagree the answer is the new copy — a wrong split is a second
book you can see and repair by moving pages, while a wrong merge interleaves two notebooks inside
one captured file and could only be repaired by cutting it.

## Configuration

`~/.config/brainio-pen/config.json`, created with defaults on first launch. Missing keys keep their defaults.

| Key | Default | Meaning |
|---|---|---|
| `dataPath` | `~/Brainio/pen` | Where the notes are kept. Created, and `git init`ed so changes can be seen as a diff. No remote is needed or added. Notes from an older `repoPath` are copied in once, and the old directory is left untouched. |
| `quietMinutes` | `10` | Minutes without strokes before a page is published. |
| `penMac`, `penPeripheralId` | none | Filled in automatically on first pairing. Delete both (or use the menu) to pair another pen. |
| `penPassword` | none | PIN for a locked pen. Sent once per connection; never retried, because repeated wrong PINs factory-reset the pen. |
| `deleteFromPenAfterPublish` | `true` | Free pen memory once a notebook is safely committed. |
| `gitPush` | `false` | Push after each commit. Off by default, so notes stay on this Mac. Turn it on only after adding an `origin` remote; with it on and no remote you are notified once and pushing stays off for that run. |
| `lowBatteryPercent` | `20` | Notify at or below this level when not charging. |
| `memoryWarnPercent` | `70` | Notify when pen memory usage reaches this level. |
| `controlBooks` | `["s3/o1013/b1"]` | Printed control surfaces rather than paper to write on. Taps on them are kept as evidence and decoded as settings, but they are never pages. |
| `sdkDebugLog` | `false` | Print the SDK's protocol log. |

## Layout

Four layers, each unable to reach the one above it. See [ADR-003](../docs/adrs/003-ui-layer-separate-from-the-pen-sdk.md).

- `Sources/BrainioPenCore` — no SDK dependency, no AppKit, fully unit-tested: models and JSONL serialisation, `StrokeAssembler` (dots → strokes), `RawStore` (append-only files), `QuietTracker` (what is pending and when it publishes), `Notebook`/`PageNaming` (how a page is described to a person), `GitPublisher`, `SyncCoordinator` (write, track, publish, back off, notify), `Config`, notifiers.
- `Sources/BrainioPenUI` — every window and view, and no SDK: `PanelModel` (one observable snapshot fed by the existing `onChange` closures), `StatusPanel` (SwiftUI), `StatusIcon` (the pencil and its states), `Viewer`, the pinned and menubar panels, the settings window. `PenLink` is the whole of what it knows about a pen — a protocol of plain values, so the layer builds and runs with no pen and no SDK linked in.
- `Sources/BrainioPen` — the app: `PenSession` (NISDK3 delegates, connection and drain state machine, and the only conformance to `PenLink`), `SDKMapping`, `AppDelegate` (status item and popover), `UserNotifier`.
- `Sources/BrainioPenDesign` + `Sources/BrainioPenDesignApp` — the design window and its fixtures, and the `brainio-pen-design` executable that opens it. Nothing else imports these, so none of it ships.
- `Tests/BrainioPenCoreTests` — includes tests that drive real `git` in a temporary repository.

## Not yet verified against hardware

Written from the SDK source without a pen. Things to confirm on first contact: the advertisement carries the MAC (otherwise reconnect falls back to the CoreBluetooth identifier), the authorised message arrives before we call `requestUsingAllNote`, the 100 % status marks the end of a notebook transfer, and the delete confirmation message arrives after deletion.
