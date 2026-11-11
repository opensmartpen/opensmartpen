# Brainio Pen

A macOS menubar app that captures what a Neo smartpen writes and uploads it to one S3 bucket. Read `README.md` for the map of the repo and `docs/architecture.md` for the system.

## What the app is, and is not

The app captures strokes, keeps them in `~/Brainio/pen`, and uploads each page to the bucket as strokes and a PNG. That is all of it (decided 2026-11-11, see `docs/decisions.md`).

Do not add these back to the app: transcription, actions, agents, DAM calls, git. Transcription happens on the other side of the bucket. The app only shows the result: the viewer fetches `transcripts/<copy>/p<N>.md` for the page on screen.

## The contract with the other side

`docs/processing.md` is the contract with whatever reads the bucket: the layout, the upload order, how time is read, and the exact instructions the reader was given.

If you change what the app uploads, where, or when, update `docs/processing.md` in the same change, and tell the user that the reader needs the new instructions.

## Working here

- The app is in `app/`. Build and test from there: `swift build`, `swift test`. The tests need no network and no pen.
- Install a build with `app/scripts/make-app.sh` and then `app/scripts/install-launchagent.sh`. Do both yourself; do not ask the user to run them.
- Look at UI without a pen: `app/.build/debug/brainio-pen-design` for the panel, the same with `--settings=sync` (add `--bucket`) for the settings window, and with `--viewer=~/Brainio/pen:<copy>:<page>` for the viewer on a real page (read only). `app/scripts/shot.sh brainio-pen-design <dir>` takes a picture of it.
- Do not run the `brainio-pen` binary by hand. The installed copy is running, and two copies would both take the pen.
- Decisions go in `docs/decisions.md`; formal ones in `docs/adrs/`. Terms are in `docs/ubiquitous-language.md`.
