# Open Smart Pen

A macOS menubar app that captures what a smartpen writes and uploads it to one S3 bucket. Neo smartpens are the first pens it works with, not the only ones it is for. Read `README.md` for the map of the repo and `docs/architecture.md` for the system.

## What the app is, and is not

The app captures strokes, keeps them in `~/OpenSmartPen`, and uploads each page to the bucket as strokes and a PNG. That is all of it (decided 2026-11-11).

The app can also report to its makers how it is used and what goes wrong (telemetry, decided 2026-11-17). It is off unless a person says yes, and it is never on by default: the app asks one time at the first start (decided 2026-11-19). The built-in address is the collector of the project, `https://telemetry.opensmartpen.org`. What the question says must be true: do not add a sentence about how the data is sent or kept that the code or a contract does not back. It never reports what was written. `docs/telemetry.md` is the list of what is sent.

Do not add these back to the app: transcription, actions, agents, calls to an agent platform, git. Transcription happens on the other side of the bucket. The app only shows the result: the viewer fetches `transcripts/<copy>/p<N>.md` for the page on screen.

## The contract with the other side

`docs/processing.md` is the contract with whatever reads the bucket: the layout, the upload order, how time is read, and the exact instructions the agent was given.

If you change what the app uploads, where, or when, update `docs/processing.md` in the same change, and tell the user that the agent needs the new instructions.

An agent learns all of this from the website, not from this repository: `https://opensmartpen.org/llms.txt` is where it starts, and `https://opensmartpen.org/agent-install.md` is the setup text it follows. Both are files in the `web` repository (`public/llms.txt`, `public/agent-install.md`), and `docs/agent-install.md` here is the original of the second. While you work, and before each commit and push, ask whether the change makes either of them wrong: a new file or field an agent reads, a new way to add a page, a changed name in the app, a changed rule. If it does, change `docs/agent-install.md` here, copy it to the `web` repository, correct `llms.txt` there, and tell the user that the website needs a push.

## Working here

- The app is in `app/`. Build and test from there: `swift build`, `swift test`. The tests need no network and no pen.
- To install a build on the Mac you work on: `app/scripts/make-app.sh`, then `app/scripts/install-launchagent.sh`. The second one replaces the installed app and sets it to start at login. Run it only when the user asked for the build to be installed, or works on this app each day and expects it; then run both yourself.
- Look at UI without a pen: `app/.build/debug/opensmartpen-design` for the panel, the same with `--settings=sync` (add `--bucket`) for the settings window, and with `--viewer=~/OpenSmartPen:<copy>:<page>` for the viewer on a real page (read only). `app/scripts/shot.sh opensmartpen-design <dir>` takes a picture of it.
- Do not run the `opensmartpen` binary by hand. The installed copy is running, and two copies would both take the pen.
- Telemetry: call `Telemetry.event`, `Telemetry.span`, `Telemetry.count` or `Telemetry.measure` from `OpenSmartPenCore`; only `OTelTelemetry.swift` imports the OpenTelemetry SDK. If you add, change or remove an event, a span or a metric, update `docs/telemetry.md` in the same change. A metric is made in `TelemetryMetric`, and its attributes are a few fixed words: never the address of a pen. Never put in an event: what was written, a notebook title, a name a person gave a pen, a file name, anything about the bucket.
- A `Log.warn` or `Log.error` line is sent as telemetry. Do not put a name that a person gave to something in one. If the line needs such a name, write `Log.warn("…", telemetry: false)`.
- The decision log is not in this repository. The maintainers keep it in their private `product` repository, at `engineering/decisions.md`; on a maintainer's Mac that is `../product/engineering/decisions.md`. Write a decision there when that folder exists. When it does not, tell the user the decision and add no log here.
- This repository is public. Do not write here: the name of a person, another product of the company, a remark about a vendor or its license, or a legal question that is open.
- A formal decision record goes in `docs/adrs/`, written for a reader outside. Terms are in `docs/ubiquitous-language.md`.
