# Architecture

Early stage. This page is the entry point the skills expect; it will grow as components land.

## System context

Pen (today a Neo smartpen on Ncode paper) → Bluetooth → **Open Smart Pen** (macOS menubar app on NISDK3) → captured JSONL per page, under `~/OpenSmartPen/books/<copy>/raw/`, and a PNG of each page under `pages/`, drawn once the pen has been quiet for 30 seconds → optionally an **S3 bucket** (the same files). The app stops there: it does not transcribe, runs no agents and keeps no git history. Whatever turns pages into text reads the folder or the bucket; the two have one layout. See `app/README.md`, "The bucket", for the layout.

One more thing leaves the Mac, and it is not pages: the app → OTLP over HTTP → a **collector** of the project. It carries how the app is used and what goes wrong, never what was written. See `docs/telemetry.md`.

## Pages

- `app/README.md` — the macOS capture app: what it does, config, layout, what is unverified.
- `docs/processing.md` — the contract with whatever reads the folder or the bucket: what the app writes, how time is to be read, and the instructions given to the agent.
- `docs/telemetry.md` — what the app reports to its makers, when, and how to turn it off.
- `docs/stroke-format.md` — raw and derived file formats, geometry.
- `docs/adrs/` — formal decision records.
- `docs/ubiquitous-language.md` — glossary.
