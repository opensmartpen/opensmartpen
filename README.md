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
- Transcribing a page runs in a DAM agent: the app draws a quiet page, uploads the PNG and asks for one turn, and files the Markdown that comes back. See `docs/processing.md` and `docs/adrs/DRAFT-a-page-is-transcribed-by-an-agent.md`. Set it up in Settings → Agents, and prove the connection with `brainio-pen --check-dam`.
- The rest of processing (SVG, geometry, a note index) is not built; `pipeline/` holds what exists.
- `docs/adrs/` — architecture decision records.
