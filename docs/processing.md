# Processing (the other side of the bucket)

Brainio Pen stops at the bucket. It captures pages and uploads them; it does not transcribe. This page is the contract with whatever reads the bucket, so the two halves stay aligned. Change the app's uploads and this page changes with them.

The reader today is an agent that sweeps the bucket. The instructions it was given are at the bottom, word for word.

## What the app writes

Under the bucket, and under the folder set in Settings → Sync if there is one:

```
books/<copy>/book.json        notebook title, paper size, first_page
books/<copy>/raw/p<N>.jsonl   strokes of one page (format: docs/stroke-format.md)
books/<copy>/pages/p<N>.png   image of that page, drawn from those strokes
pens/<slug>.json              each pen's name, mode, default ink and width
mode.jsonl, palette.json      which ink and width was in force when, and what each ink looks like
brainio-pen-connected.txt     written once when the bucket is connected; not a note
```

- **One direction, with one exception.** The app writes under `books/`, `pens/` and the two ink files. It never lists and never deletes, so anything the reader stores in the bucket is left alone. The one thing it reads is the transcript of a page that is open in the viewer (see below).
- **When.** Pages go up once no pen has reported any event for `quietSeconds` (30 by default). The wait is on the pen, not on each page, so the pages of one sitting arrive together. Pages drained from pen memory go up as soon as the notebook has been transferred.
- **Order.** The strokes first, then the PNG. The PNG is the object to trigger on: when it lands, its strokes are already there.
- **Replaced whole.** A page written on again is uploaded again under the same two keys. The PNG always shows the whole page, cropped to the ink, so its size changes as the page grows.
- **The control strip.** `books/s3-o1013-b1-*` is the printed strip of colour and width buttons. Its taps are uploaded as strokes, because they are the record, but it gets no PNG and it is not a notebook.
- **Colour.** The PNG is already drawn in the right inks. `mode.jsonl` and `palette.json` are only needed by a reader that draws pages itself.

## Time

The upload time says when the Mac was reachable, not when anything was written: a pen used away from the Mac uploads hours later. The writing time is in the stroke file. Every `"t":"stroke"` line carries `start` and `end` in epoch milliseconds. Lines are in arrival order, not time order, so a reader sorts by `start`.

A page can hold writing from several sittings, days apart. A reader that wants to say which meeting some notes belong to groups the strokes by gaps in time and matches each group, not the page.

The limit of this: the transcript is made from the image, so a reader can tell which text is new by comparing with its last transcript, and it has time ranges for the page from the strokes, but nothing ties one line of text to one moment.

## What the reader writes

Transcripts go to `transcripts/<copy>/p<N>.md` in the same bucket. Not under `books/`: that is the app's side, and a reader that sweeps for changed files would otherwise be woken by its own output.

The app shows them. When a page is open in the viewer with the transcript pane on (the button in the bar, or T), the app fetches that one file by name, shows it beside the ink, and asks again every 30 seconds while the pane is open. Each transcript fetched is kept at the same path under `~/Brainio/pen`, so it can be read offline. The path is therefore part of the contract: move the transcripts and the pane goes empty. The key needs permission to read as well as to write.

The pane draws Markdown a line at a time: `# ` as the title, `## ` as a heading (the reader uses it for when a part was written and which meeting it belongs to), `- ` as a bullet, and emphasis and `~~struck~~` inside a line. Line breaks are kept as written. Anything else is shown as plain text.

## Open

- Grouping pages into notes. Candidates: same book plus a time gap (Neo Studio 2 uses 15 minutes), or a hand-drawn marker in a page corner. Tracked in `docs/landscape-log.md`.
- Whether `pens/`, `mode.jsonl` and `palette.json` should go up at all while the only reader transcribes from the PNG.

## The instructions given to the reader

Sent 2026-11-11. `<BUCKET>` and `<PREFIX>` were filled in.

```
My smart pen writes to S3 bucket <BUCKET>, folder <PREFIX>. Add it to the sweep.

Layout (the Mac app only writes here; it never reads or deletes):
  books/<copy>/book.json        notebook title, paper size, first_page
  books/<copy>/raw/p<N>.jsonl   strokes of one page
  books/<copy>/pages/p<N>.png   image of that page
  pens/<slug>.json              pen names
  mode.jsonl, palette.json      ink colour data (already drawn into the PNG)
Ignore brainio-pen-connected.txt and the folder books/s3-o1013-b1-* (a control strip, not notes).

How it updates:
- Pages upload 30 seconds after the last event from the pen. The jsonl goes first, the PNG second.
  Trigger on the PNG.
- Both files are replaced whole each time. The PNG always shows the full page, old and new
  writing, cropped to the ink. Pages only grow; I do not erase.

Transcribe:
- For each new or changed PNG, transcribe the full page as plain text. No summary, no cleanup.
- Read your previous transcript of that page first. Keep the earlier text stable and add what
  is new, so you know which part is new.
- Store it at transcripts/<copy>/p<N>.md in the same bucket. Do not write under books/.

Time (important):
- Do not use the S3 upload time. The pen also works offline and uploads hours later.
- Each line in the jsonl with "t":"stroke" has "start" and "end" in epoch milliseconds. That is
  when I wrote it. Lines are not in time order; sort by "start".
- One page can hold writing from several sessions. Group strokes by gaps in time, then match
  each group to the meeting in my calendar at that time. Notes written in a meeting are context
  for that meeting.
- Page number for people = N - first_page + 1. Notebook name = "title" in book.json.
```
