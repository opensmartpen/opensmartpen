# PenBridge

macOS menubar app that keeps a Neo smartpen's strokes flowing into a git repository with no attention from the user. It does not render or transcribe anything; that is the processing side's job (see `../docs/processing.md`).

## What it does

- Scans for the pen whenever none is connected. The first pen ever seen is paired and remembered; after that only that pen is accepted.
- On connect: authorises (sends the configured PIN once if the pen asks), sets the pen clock, subscribes to all notebooks, then drains offline memory one notebook at a time.
- Live strokes are appended to `raw/s{section}/o{owner}/b{book}/p{page}.jsonl` in the notes repo as they finish.
- A page is published when it has been quiet for `quietMinutes` (default 10): its file is committed and pushed. Only quiet pages are committed, so a half-written page never lands in git.
- Offline strokes are published as soon as a notebook has been fully transferred. Only after the commit and push succeed is that notebook deleted from the pen.
- Failures are retried with backoff and surfaced as macOS notifications after three attempts. Battery, memory, PIN, duplicate connection and stalled transfers also notify. Normal operation is silent.

The menubar item shows connection state, battery and memory, pending pages and the last publish, and offers Publish now, Pair a different pen, Open notes folder, Open config file.

## Build and run

Requires Xcode 15+ (Swift 5.9) on macOS 13+. Depends on NeoLAB's `NISDK3` (GPL-3.0) via SwiftPM, pinned to tag 1.1.5.

```sh
cd PenBridge
swift test                         # core logic, no hardware needed
scripts/make-app.sh                # dist/PenBridge.app, ad-hoc signed
open dist/PenBridge.app
scripts/install-launchagent.sh     # start at login, restart on exit, logs in ~/Library/Logs/PenBridge
```

Running the bare binary with `swift run` also works for debugging (stderr log, AppleScript notifications), but Bluetooth permission is then attributed to the terminal and macOS notifications are unavailable. Set `PENBRIDGE_VERBOSE=1` for debug logging.

## Configuration

`~/.config/penbridge/config.json`, created with defaults on first launch. Missing keys keep their defaults.

| Key | Default | Meaning |
|---|---|---|
| `repoPath` | `~/PenBridge/notes` | Git repository receiving raw files. Created and `git init`ed if missing. Add an `origin` remote yourself; without one commits stay local and you are notified once. |
| `quietMinutes` | `10` | Minutes without strokes before a page is published. |
| `penMac`, `penPeripheralId` | none | Filled in automatically on first pairing. Delete both (or use the menu) to pair another pen. |
| `penPassword` | none | PIN for a locked pen. Sent once per connection; never retried, because repeated wrong PINs factory-reset the pen. |
| `deleteFromPenAfterPublish` | `true` | Free pen memory once a notebook is safely in git. |
| `gitPush` | `true` | Push after each commit. |
| `lowBatteryPercent` | `20` | Notify at or below this level when not charging. |
| `memoryWarnPercent` | `70` | Notify when pen memory usage reaches this level. |
| `sdkDebugLog` | `false` | Print the SDK's protocol log. |

## Layout

- `Sources/PenBridgeCore` — no SDK dependency, fully unit-tested: models and JSONL serialisation, `StrokeAssembler` (dots → strokes), `RawStore` (append-only files), `QuietTracker`, `GitPublisher`, `SyncCoordinator` (write, track, publish, back off, notify), `Config`, notifiers.
- `Sources/PenBridge` — the app: `PenSession` (NISDK3 delegates, connection and drain state machine), `SDKMapping`, `AppDelegate` (menubar), `UserNotifier`.
- `Tests/PenBridgeCoreTests` — includes tests that drive real `git` in a temporary repository.

## Not yet verified against hardware

Written from the SDK source without a pen. Things to confirm on first contact: the advertisement carries the MAC (otherwise reconnect falls back to the CoreBluetooth identifier), the authorised message arrives before we call `requestUsingAllNote`, the 100 % status marks the end of a notebook transfer, and the delete confirmation message arrives after deletion.
