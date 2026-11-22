# Ubiquitous language

Terms used in this project, kept precise. Update inline when a term is resolved.

- **Dot** — one sample from the pen: x, y in Ncode cells, force, time delta, tilt, twist, plus the page identity. ~120 per second while writing.
- **Stroke** — the dots between one pen-down and the next pen-up. One of the three kinds of captured event.
- **Page** — one physical sheet side, identified by Ncode (section, owner, book, page). The unit of storage: one captured file, one SVG, one PNG, one Markdown — all inside the folder of the copy that holds it.
- **Book** — a physical notebook as encoded in Ncode (the `note`/`book` field). It names a *product*, not a copy: every LAMY notebook in the world reports the same code. Our two books: NeoLAB A4 Ncode paper is section 3 / owner 27 / book 450; LAMY digital paper is section 3 / owner 1012 / book 3017 (LAMY has its own owner code).
- **Copy** — one physical notebook on the desk. Two pads of one product are two copies sharing a surface identity, so each gets a folder of its own, `books/s3-o27-b450-7f3a9c`, named by that identity and a generated id. The id is opaque and permanent; `book.json` inside is the only authority on what the copy is.
- **Ncode cell** — the pattern's unit of length, 2.371 mm. All raw coordinates are in cells.
- **Geometry** — a book's page rectangle and margins in cells. Needed only to render. Measured from the strokes in practice: `.nproj` files exist but there is no public source for our books.
- **Event** — one thing that happened, recorded at the moment it happened: a stroke, a setting or a command. Lost if not recorded then.
- **Active area** — a region of a page that also means something. Writing in it still makes a stroke, which is kept and drawn as usual; on top of that it produces a setting or a command. Where the areas are comes from the paper's own metadata. The paper controller's swatches are the only ones today.
- **Surface identity** — the sheet or canvas a mark was made on. Only a client that senses a surface can give one, so only such a client can make strokes. For the pen it is the Ncode address; another client would bring its own form.
- **Client** — the thing that produced an event. Two today: the pen and the app, and there can be more. Only a client that reads Ncode paper can make strokes, because only it knows which page a mark is on; every other client makes settings and commands alone. A raw file's `client` field names the software build that wrote the line, which is the Mac app in both cases.
- **Setting** — an event that changes how we draw or read the marks, such as a new ink colour. Replayed every time a readable file is made.
- **Command** — an event that asks for work, such as "share this page". Done one time only; remaking the page must not send it again.
- **Raw** — the append-only record of every captured event. Source of truth. Never edited, only appended to. A copy's `raw/` holds its per-page stroke files; `mode.jsonl` sits at the root, because a setting has no surface to file it under.
- **Derived** — anything regenerated from raw: SVG, PNG, Markdown transcription, note index. Lives in a copy's `pages/`, under the same page name as the captured file it was made from. Never edited by hand; deleting all of it costs nothing.
- **Live** — dots received over Bluetooth while the pen is connected.
- **Offline** — strokes stored in pen memory while disconnected and drained on reconnect. Same data, different `src`.
- **Quiet page** — a page with no new strokes for the debounce window (default 10 minutes). Only quiet pages are published for processing.
- **Publish** — hand a quiet page's raw file on for processing. The destination is undecided; a publish must confirm, because pen memory is cleared only after it does.
- **Transcription** — the Markdown text derived from a page by handwriting recognition (stroke-based or image-based).
- **Agent** — the program on the other side that works with the files the app wrote, in the folder or in the bucket, and writes the transcription. For example Claude Code, Codex or Claude Desktop. Not a part of the app; `docs/processing.md` is the contract with it.
- **Telemetry** — what the app reports to its makers about how it is used and what goes wrong. Never what was written. On unless the person turns it off: in the first window, which shows the switch before anything is sent, or in Settings. `docs/telemetry.md` is the list.
- **Telemetry event** — one thing the app reports: a click, a pen that connected, a problem. Not an **Event**: an event is captured from a client and kept in raw; a telemetry event is about the app and is kept by the collector.
- **Install id** — a random id for one install of the app on one Mac, sent with all telemetry. Kept outside the app, so it stays when the app is installed again. It says "the same install" and nothing about the person.
- **Collector** — the server that takes the telemetry. The project's own is at `https://telemetry.opensmartpen.org`, and that address is built into the app.
- **Note** — a user-meaningful grouping of pages (by book, time gap, or marker). Derived and not yet defined.
