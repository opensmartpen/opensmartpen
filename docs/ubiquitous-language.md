# Ubiquitous language

Terms used in this project, kept precise. Update inline when a term is resolved.

- **Dot** — one sample from the pen: x, y in Ncode cells, force, time delta, tilt, twist, plus the page identity. ~120 per second while writing.
- **Stroke** — the dots between one pen-down and the next pen-up. The unit of capture and of the raw file.
- **Page** — one physical sheet side, identified by Ncode (section, owner, book, page). The unit of storage: one raw file, one SVG, one PNG, one Markdown.
- **Book** — a physical notebook as encoded in Ncode (the `note`/`book` field). Our two books: NeoLAB A4 Ncode paper is section 3 / owner 27 / book 450; LAMY digital paper is section 3 / owner 1012 / book 3017 (LAMY has its own owner code).
- **Ncode cell** — the pattern's unit of length, 2.371 mm. All raw coordinates are in cells.
- **Geometry** — a book's page rectangle and margins in cells, from a `.nproj` file or measured. Needed only to render.
- **Raw** — the append-only JSONL stroke log per page. Source of truth. Never edited.
- **Derived** — anything regenerated from raw: SVG, PNG, Markdown transcription, note index. Never edited by hand.
- **Live** — dots received over Bluetooth while the pen is connected.
- **Offline** — strokes stored in pen memory while disconnected and drained on reconnect. Same data, different `src`.
- **Quiet page** — a page with no new strokes for the debounce window (default 10 minutes). Only quiet pages are published for processing.
- **Publish** — commit and push a quiet page's raw file to the GitHub repo. Triggers processing.
- **Transcription** — the Markdown text derived from a page by handwriting recognition (stroke-based or image-based).
- **Note** — a user-meaningful grouping of pages (by book, time gap, or marker). Derived and not yet defined; see `docs/decisions.md`.
