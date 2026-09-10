# smart-pen

Digitise handwritten notes from a Neo smartpen (A1, Ncode paper) into a GitHub-backed store of raw strokes, SVG renders and Markdown transcriptions.

- `RESEARCH.md` — SDK, protocol, vendor app, field and DAM research (2026-09-10).
- `docs/architecture.md` — system overview and entry point to the docs.
- `docs/stroke-format.md` — the raw JSONL stroke format and derived files.
- `docs/decisions.md` — running decision log; formal records in `docs/adrs/`.
- `docs/landscape-log.md` — how other products solve each concern, and how we differ.
- `docs/ubiquitous-language.md` — glossary.

Components:

- `PenBridge/` — macOS menubar app on NeoLAB's NISDK3 that syncs raw strokes to a git repo. Builds and is unit-tested; not yet run against a pen.
- Processing (render, transcribe) runs in a DAM agent off the notes repo; see `docs/processing.md`. Not built yet.
- `docs/adrs/` — architecture decision records.
