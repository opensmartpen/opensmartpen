# Processing (the DAM side)

Not built yet. This page records what the processing agent is expected to do with the raw files Brainio Pen publishes, so the two halves stay aligned. ADR-005 ends at the raw file; how those files reach this side is undecided, so the input described below is the shape we are working towards, not a settled contract.

## Input

Raw page files (format: `docs/stroke-format.md`; where they live: ADR-002), delivered in batches. Every batch holds only pages that had gone quiet or were drained from pen memory, so each one is a set of finished pages (ADR-004).

## Expected outputs, per page

- `pages/.../p{page}.svg` — strokes as paths, width from force, page rectangle from geometry.
- `pages/.../p{page}.png` — raster of the SVG at a resolution suited to vision models (roughly 150 dpi).
- `pages/.../p{page}.md` — transcription with frontmatter: page id, first and last stroke time, stroke count, model, confidence or a flag for unreadable regions.
- `geometry/s{section}-o{owner}-b{book}.json` — page rectangle and margins, discovered once per book (from NeoLAB's `.nproj` via the Web SDK's storage path, else measured from strokes assuming A4 or A5).

Derived files are regenerated from raw whenever raw changes and are never hand-edited.

## Trigger

The agent runs always-on. Options, in order of preference once DAM offers them: a git push webhook into the agent; otherwise a schedule that polls the repo every few minutes and processes pages whose raw file is newer than their derived files.

## Transcription approach

Baseline is image-based: render the page and ask Claude to transcribe it into Markdown, preserving the original language (Czech or English), lists and headings, and marking illegible words rather than guessing. Stroke-based recognition (Google ML Kit Digital Ink) is an experiment to compare against the baseline; if it wins, it runs first and Claude cleans up. Expect 6–12 % character error on rushed handwriting and confident hallucination as the main failure mode; always keep the PNG next to the text.

## Grouping into notes

Deferred. Candidates: same book plus a time gap (Neo Studio 2 uses 15 minutes), or a hand-drawn marker in a page corner. Tracked in `docs/landscape-log.md`.
