# Brainio Pen

Digitise handwritten notes from a Neo smartpen (A1, Ncode paper) into a store of captured strokes, SVG renders and Markdown transcriptions at `~/Brainio/pen`. Everything stays on this Mac; nothing is pushed to a remote.

- `RESEARCH.md` — SDK, protocol, vendor app, field and DAM research (2026-09-10).
- `docs/architecture.md` — system overview and entry point to the docs.
- `docs/stroke-format.md` — the raw JSONL stroke format and derived files.
- `docs/decisions.md` — running decision log; formal records in `docs/adrs/`.
- `docs/landscape-log.md` — how other products solve each concern, and how we differ.
- `docs/ubiquitous-language.md` — glossary.

Components:

- `app/` — the Brainio Pen macOS menubar app, on NeoLAB's NISDK3, filing captured strokes under `~/Brainio/pen`. Called PenBridge until 2026-09-12; see `app/README.md` for what the rename moved.
- Transcribing is not done by the app. It uploads each page to an S3 bucket, as strokes and a PNG, and whatever reads the bucket transcribes. `docs/processing.md` is the contract with that reader, and holds the instructions it was given.
- `pipeline/` — earlier local scripts for rendering and transcribing. Not used by the app.
- `docs/adrs/` — architecture decision records.

## License

- The source code in this repository is licensed under Apache-2.0. See `LICENSE`.
- The app links NISDK3, NeoLAB's pen SDK, which is GPL-3.0. A built copy of the app is thus distributed under GPL-3.0 as a whole. See `NOTICE`.
- NISDK3 is not in this repository. The build downloads it.
- Brainio Pen is not affiliated with NeoLAB Convergence, Inc.
