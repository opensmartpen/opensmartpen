# Architecture

Early stage. This page is the entry point the skills expect; it will grow as components land.

## System context

Pen (Neo smartpen A1, Ncode paper) → Bluetooth → **Brainio Pen** (macOS menubar app on NISDK3) → captured JSONL per page, under `~/Brainio/pen/books/<copy>/raw/` → **S3 bucket** (the same files, plus a PNG of each page, uploaded once a page has been quiet for 30 seconds). The app stops there: it does not transcribe, runs no agents and keeps no git history. Whatever turns pages into text reads the bucket. See `app/README.md`, "The bucket", for the layout.

## Pages

- `app/README.md` — the macOS capture app: what it does, config, layout, what is unverified.
- `docs/processing.md` — the contract with whatever reads the bucket: what the app uploads, how time is to be read, and the instructions given to the reader.
- `docs/stroke-format.md` — raw and derived file formats, geometry.
- `docs/decisions.md` — running decision log; formal records go to `docs/adrs/`.
- `docs/landscape-log.md` — how other products solve each concern and how we differ.
- `docs/ubiquitous-language.md` — glossary.
- `RESEARCH.md` — SDK, protocol, app, field and DAM research (2026-09-10).
