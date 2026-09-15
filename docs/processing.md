# Processing (the DAM side)

This page records what the processing agent is expected to do with what Brainio Pen sends it, so the two halves stay aligned.

Reading a page is built and is described by `docs/adrs/DRAFT-a-page-is-read-by-an-agent.md`: the app draws the page, puts the PNG in the agent's workspace and asks for one turn. The rest below — SVG, geometry, a note index — is not built, and still runs off the captured files.

## Input

Two shapes, for two jobs.

**Reading a page.** The app uploads `pen/<copy>/p<n>.png` into the agent's workspace, and `pen/<copy>/p<n>.md` and `pen/<copy>/p<n>.actions.json` as well when it already has them. Then it prompts the agent once and waits. The agent writes the Markdown and the actions; the app reads both back and files them beside the captured strokes. Every page sent this way has been still for a minute, so it is finished for now — and it is sent again whenever it is written on again.

**Who does what.** One key, several agents. The one that reads pages is chosen for having no confidential connections — it sees whatever the paper says, and paper is untrusted. Every other agent is asked once, in one turn, for a one-sentence summary and the list of systems it can reach; that roster goes into the reading prompt, and the reader puts an `"agent"` on each `>>` line saying who should carry it out. It is a proposal in a file: the reader cannot send anything anywhere, the chip on the row shows the choice before any work is sent, and a person can change it. An unrouted line goes to the reader, which can reach nothing.

**Carrying out one line.** The same parcel, a different prompt: one `>>` line named, the rest of the page explicitly left alone, and everything said about it so far. The turn writes no files. The agent replies with the answer itself and ends with one line, `STATUS: done`, `STATUS: needs-info` or `STATUS: blocked`; the app files the reply in that action's `thread` and ticks the box only on `done`. Turns after the first send `session/load` with the session id kept from the last one, so the agent carries on where it stopped. Only a click starts any of this. A reading never does.

**Everything else.** Raw page files (format: `docs/stroke-format.md`; where they live: ADR-002). How those reach this side is undecided.

## Expected outputs, per page

- `books/<copy>/pages/p{page}.svg` — strokes as paths, width from force, page rectangle from geometry.
- `books/<copy>/pages/p{page}.png` — raster of the SVG at a resolution suited to vision models (roughly 150 dpi).
- `books/<copy>/pages/p{page}.md` — transcription with frontmatter: page id, first and last stroke time, stroke count, model, confidence or a flag for unreadable regions.
- `geometry/s{section}-o{owner}-b{book}.json` — page rectangle and margins, discovered once per book (from NeoLAB's `.nproj` via the Web SDK's storage path, else measured from strokes assuming A4 or A5).

Derived files are regenerated from raw whenever raw changes and are never hand-edited. One file is not derived: `books/<copy>/pages/p{page}.actions.json`, a list of `{text, done, dismissed, note, thread, session, agent}`. A reading proposes what is on the page and may set `done` or `dismissed`; nothing but a person can clear either.

## Trigger

The app decides, and the upload wakes the agent. There is no schedule and no polling on the agent's side: a DAM agent runs in a pod and cannot see `~/Brainio/pen`, and DAM has no trigger for a changed file.

A page is due when its captured file is newer than its reading. That question is asked of the files on this Mac, every 30 seconds, and answered the same way after a restart as before one (ADR-004).

## Transcription approach

Image-based: the app draws the page and the agent reads the picture into Markdown, preserving the original language (Czech or English), lists and headings, and marking illegible words rather than guessing. Stroke-based recognition (Google ML Kit Digital Ink) is an experiment to compare against the baseline; if it wins, it runs first and Claude cleans up. Expect 6–12 % character error on rushed handwriting and confident hallucination as the main failure mode; always keep the PNG next to the text.

## Grouping into notes

Deferred. Candidates: same book plus a time gap (Neo Studio 2 uses 15 minutes), or a hand-drawn marker in a page corner. Tracked in `docs/landscape-log.md`.
