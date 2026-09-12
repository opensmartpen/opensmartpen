# Architecture

Early stage. This page is the entry point the skills expect; it will grow as components land.

## System context

Pen (Neo smartpen A1, Ncode paper) → Bluetooth → **Brainio Pen** (macOS menubar app on NISDK3) → raw JSONL per page → **GitHub repo** → **pipeline** (render SVG/PNG, transcribe to Markdown) → derived files committed back. A DAM agent may later run the pipeline; see `RESEARCH.md` section 4 for what DAM offers.

## Pages

- `app/README.md` — the macOS capture app: what it does, config, layout, what is unverified.
- `docs/processing.md` — what the DAM agent is expected to do with the raw files.
- `docs/stroke-format.md` — raw and derived file formats, geometry.
- `docs/decisions.md` — running decision log; formal records go to `docs/adrs/`.
- `docs/landscape-log.md` — how other products solve each concern and how we differ.
- `docs/ubiquitous-language.md` — glossary.
- `RESEARCH.md` — SDK, protocol, app, field and DAM research (2026-09-10).
