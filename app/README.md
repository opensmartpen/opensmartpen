# Brainio Pen

macOS menubar app that keeps a Neo smartpen's strokes flowing into a git repository with no attention from the user. It does not render or transcribe anything; that is the processing side's job (see `../docs/processing.md`).

## What it does

- Scans for the pen whenever none is connected. The first pen ever seen is paired and remembered; after that only that pen is accepted.
- On connect: authorises (sends the configured PIN once if the pen asks), sets the pen clock, subscribes to all notebooks, then drains offline memory one notebook at a time.
- Live strokes are appended to `raw/s{section}/o{owner}/b{book}/p{page}.jsonl` in the notes repo as they finish.
- A page is published when it has been quiet for `quietMinutes` (default 10): its file is committed and pushed. Only quiet pages are committed, so a half-written page never lands in git.
- Offline strokes are published as soon as a notebook has been fully transferred. Only after the commit and push succeed is that notebook deleted from the pen.
- Failures are retried with backoff and surfaced as macOS notifications after three attempts. Battery, memory, PIN, duplicate connection and stalled transfers also notify. Normal operation is silent.

## The menubar panel

The menubar item is a pencil, in every state — an icon that turns into a battery symbol when the battery is low disappears exactly when you go looking for it. A drop of ink beside the pencil means pages are written but not yet committed; the pencil goes red with a percentage below `lowBatteryPercent`, and dims when no pen is connected.

Clicking it opens a SwiftUI panel (`NSPopover`, 320 pt) that answers one question: is my writing safe?

- **Every waiting page, counted down.** Each pending page is listed with the time left in its quiet window, so the ten-minute wait is visible instead of invisible. The page being written right now has no countdown — its timer restarts on every stroke — and carries a live dot instead.
- **Pages are named, not numbered in Ncode.** `notebooks` in the config maps a book to a name the person uses. Ncode page numbers are not the printed ones (the LAMY pad's first written sheet reported as page 4), so a page number is shown only for a notebook whose `firstPage` has been calibrated; otherwise just the name.
- **Battery is a gauge; pen memory is not.** Battery is a level — always relevant, fixed by charging. Pen memory is a backlog: normally zero, only filling when you write away from this Mac, and it empties itself on connect. It gets a line of prose under the battery when there is something to say, and a progress bar while a transfer is running.
- **Failures lead with the reassurance.** When a push keeps failing the panel says how many pages are safe on disk before it says anything about git.
- Colour only appears when it means something: violet for work in flight, amber for something to know, red for something to fix. The resting state has no colour at all.

## Build and run

Requires Xcode 15+ (Swift 5.9) on macOS 13+. Depends on NeoLAB's `NISDK3` (GPL-3.0) via SwiftPM, pinned to tag 1.1.5.

```sh
cd app
swift test                         # core logic, no hardware needed
scripts/make-app.sh                # dist/BrainioPen.app, ad-hoc signed
open dist/BrainioPen.app
scripts/install-launchagent.sh     # start at login, restart on exit, logs in ~/Library/Logs/BrainioPen
```

Running the bare binary with `swift run` also works for debugging (stderr log, AppleScript notifications), but Bluetooth permission is then attributed to the terminal and macOS notifications are unavailable. Set `BRAINIO_PEN_VERBOSE=1` for debug logging.

## Moving from PenBridge

The app was called PenBridge until 2026-09-12. `scripts/install-launchagent.sh` retires the old
`com.apoco.penbridge` agent and deletes `~/Applications/PenBridge.app` before installing this one,
so the two never run at once — two agents would both own the pen and both commit to the notes repo.

The config directory moved from `~/.config/penbridge/` to `~/.config/brainio-pen/`. On first launch
the old one is **copied** across, so the paired pen, the PIN and the battery history survive; the
old directory is left alone, which means an install still on the old name keeps working. Because
`repoPath` is carried over with everything else, notes stay wherever they already are —
`~/BrainioPen/notes` is only the default for a fresh install. Move them yourself if you want the
name to match, and set `repoPath` to the new path:

```sh
mv ~/PenBridge ~/BrainioPen
```

The bundle id changed from `com.apoco.penbridge` to `com.brainio.pen`. macOS ties Bluetooth and
notification permission to the bundle id, so both are asked for once more on first launch; until
Bluetooth is granted the pen will not connect. Saved window positions reset for the same reason.

## Working on the design

```
./dev-design.sh
```

Opens a detached, always-visible window showing the panel in both appearances at once, with a
picker for every state it can be in, and rebuilds and reopens it whenever a source file changes.
The window keeps its position and its selected state across a rebuild, so the loop reads as a
reload.

Design mode runs nothing else — no pen, no git, no menubar item — so it is safe to run while the
installed LaunchAgent is running. `BRAINIO_PEN_DESIGN=1 .build/debug/brainio-pen` opens the same
window without the rebuild loop.

The states come from `PanelModel.Scenario` rather than from hardware, because a failing push, a
memory drain and a first run each take deliberate setup to see even once.

## Pens and notebooks

Both are named in the repo, not in the app, because the renderer needs them too.

- `pens/<slug>.json` — name, mode (writing / accent / highlight), default ink and width. A pen is
  adopted the first time it connects, so it has a name from the start rather than a MAC address.
- `books/<slug>.json` — title, paper size, first page, and instances. A notebook gets a record the
  moment a page arrives from it. Recognised products name themselves; anything else is named after
  its paper.

In both, the slug is the filename and is fixed when the record is created. The title and the name
are free to change at any time. That split is deliberate: a slug also names the directory every
rendered page lives in, so a rename that followed the display name would move data.

Two notebooks of the same model report the same Ncode id, so a second copy is detected — writing
that starts again at the front, or a long silence followed by a distant page — and Brainio Pen asks.
It never decides: a wrong silent guess merges two notebooks into one set of files and goes
unnoticed. Confirming records a boundary date, and the derived layer routes pages by it.

## Configuration

`~/.config/brainio-pen/config.json`, created with defaults on first launch. Missing keys keep their defaults.

| Key | Default | Meaning |
|---|---|---|
| `repoPath` | `~/BrainioPen/notes` | Git repository receiving raw files. Created and `git init`ed if missing. Add an `origin` remote yourself; without one commits stay local and you are notified once. |
| `quietMinutes` | `10` | Minutes without strokes before a page is published. |
| `penMac`, `penPeripheralId` | none | Filled in automatically on first pairing. Delete both (or use the menu) to pair another pen. |
| `penPassword` | none | PIN for a locked pen. Sent once per connection; never retried, because repeated wrong PINs factory-reset the pen. |
| `deleteFromPenAfterPublish` | `true` | Free pen memory once a notebook is safely in git. |
| `gitPush` | `true` | Push after each commit. |
| `lowBatteryPercent` | `20` | Notify at or below this level when not charging. |
| `memoryWarnPercent` | `70` | Notify when pen memory usage reaches this level. |
| `notebooks` | the two books we know | Names shown in the panel, keyed by `s{section}/o{owner}/b{book}`. Set a notebook's `firstPage` to the Ncode page number of the sheet you call page 1 and the panel starts showing page numbers that match the paper. |
| `sdkDebugLog` | `false` | Print the SDK's protocol log. |

## Layout

- `Sources/BrainioPenCore` — no SDK dependency, no AppKit, fully unit-tested: models and JSONL serialisation, `StrokeAssembler` (dots → strokes), `RawStore` (append-only files), `QuietTracker` (what is pending and when it publishes), `Notebook`/`PageNaming` (how a page is described to a person), `GitPublisher`, `SyncCoordinator` (write, track, publish, back off, notify), `Config`, notifiers.
- `Sources/BrainioPen` — the app: `PenSession` (NISDK3 delegates, connection and drain state machine), `SDKMapping`, `PanelModel` (one observable snapshot fed by the existing `onChange` closures), `StatusPanel` (SwiftUI), `StatusIcon` (the pencil and its states), `AppDelegate` (status item and popover), `UserNotifier`.
- `Tests/BrainioPenCoreTests` — includes tests that drive real `git` in a temporary repository.

## Not yet verified against hardware

Written from the SDK source without a pen. Things to confirm on first contact: the advertisement carries the MAC (otherwise reconnect falls back to the CoreBluetooth identifier), the authorised message arrives before we call `requestUsingAllNote`, the 100 % status marks the end of a notebook transfer, and the delete confirmation message arrives after deletion.
