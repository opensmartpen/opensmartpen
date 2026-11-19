# Processing (the agent's side)

Open Smart Pen stops at the page. It captures pages, keeps them in `~/OpenSmartPen`, and copies them to a bucket if one is connected; it does not transcribe. This page is the contract with whatever reads the pages, so the two halves stay aligned. Change what the app writes and this page changes with it.

The folder and the bucket have one layout. An agent on the Mac reads the folder; an agent anywhere else reads the bucket. All that follows applies to both, unless it says bucket.

The agent today sweeps the bucket. The instructions it was given are at the bottom, word for word.

## What the app writes

Under `~/OpenSmartPen`, and the same under the bucket (and under the folder set in Settings → Sync if there is one):

```
books/<copy>/book.json        notebook title, paper size, first_page
books/<copy>/raw/p<N>.jsonl   strokes of one page (format: docs/stroke-format.md)
books/<copy>/pages/p<N>.png   image of that page, drawn from those strokes
pens/<slug>.json              each pen's name, mode, default ink and width
mode.jsonl, palette.json      which ink and width was in force when, and what each ink looks like
last-modified.txt             when a page picture last changed, and the version of these rules
```

- **One direction, with one exception.** The app writes under `books/`, `pens/` and the two ink files. In the bucket it never lists and never deletes, so anything the agent stores there is left alone. The one thing it reads is the transcript of a page that is open in the viewer (see below).
- **When.** Pages are drawn, and go up, once no pen has reported any event for `quietSeconds` (30 by default). The wait is on the pen, not on each page, so the pages of one sitting arrive together. Pages drained from pen memory go up as soon as the notebook has been transferred.
- **Order.** The strokes first, then the PNG, then `last-modified.txt` after the last PNG of the batch, in the folder and in the bucket. When the time file changes, every page it speaks for is already there.
- **The time file.** `last-modified.txt` is the one file to watch. It has two lines: `changed:` with the UTC time, to the millisecond, when the app last changed a page picture, and `rules:` with the version of these rules (now 1). It is written only when a picture changed, so a retry does not move it. An agent keeps the value it saw last and compares; it does not compare with a clock, because a pen used offline sends the file hours after the time in it. The file says "look now", not which pages: a page is owed when its PNG is newer than its transcript, or has none. When `rules:` is not the version an agent was set up with, its instructions are out of date. The file is absent until the first picture changes after this build was installed.
- **Photos.** A page can arrive as a picture: "Add Photo…" in the panel takes one from an iPhone or iPad or from a file, and a file can be dropped on the pen in the menu bar. Each one is the next page of a notebook the app makes, "Photos", at `books/s0-o0-b0-<id>`. The address is in the pen's form and means nothing; no paper is printed with it. The picture as it arrived is kept as `raw/p<N>.<ext>`, and `raw/p<N>.jsonl` holds one line, `{"t":"image","file":"p<N>.<ext>","added":<ms>}`, and no strokes. `added` is when the picture was filed, in epoch milliseconds. A second field, `taken`, is when the photo was taken, when that is known: from what the camera wrote into the picture, else the moment of arrival for a picture that came from an iPhone, else the file's own creation date. The sample page has none. Both go to the bucket in this file, so an agent there has them. A bucket itself keeps only the time of upload. The page picture `pages/p<N>.png` is made from it, at most 1568 pixels on the long side and turned the way the camera says is up. A photo is complete when it arrives, so it goes up at once. The only time it has is `added`.
- **The sample page.** The notebook "Photos" is made when the first picture is filed, not before. Until it exists, "Add Photo…" also offers "Use the Sample Page", a page that the app brings itself, for a person with no pen and no photo at hand. It is filed like a photo. It is drawn from a typeface for now; it will be a page written with a pen.
- **Replaced whole.** A page written on again is drawn and uploaded again under the same two names. The PNG always shows the whole page, cropped to the ink, so its size changes as the page grows. In the folder the PNG is replaced in one step and only when the picture is different, so an agent never sees half a file and is not woken for nothing.
- **The folder holds more.** `books/<copy>/pages/` on a Mac that ran earlier builds can also hold `.svg`, `.md` and `.actions.json` files. The app no longer reads or writes them, and they do not go to the bucket.
- **The control strip.** `books/s3-o1013-b1-*` is the printed strip of colour and width buttons. Its taps are uploaded as strokes, because they are the record, but it gets no PNG and it is not a notebook.
- **Colour.** The PNG is already drawn in the right inks. `mode.jsonl` and `palette.json` are only needed by an agent that draws pages itself.

## Time

The upload time says when the Mac was reachable, not when anything was written: a pen used away from the Mac uploads hours later. The writing time is in the stroke file. Every `"t":"stroke"` line carries `start` and `end` in epoch milliseconds. Lines are in arrival order, not time order, so an agent sorts by `start`.

A page can hold writing from several sittings, days apart. An agent that wants to say which meeting some notes belong to groups the strokes by gaps in time and matches each group, not the page.

The limit of this: the transcript is made from the image, so an agent can tell which text is new by comparing with its last transcript, and it has time ranges for the page from the strokes, but nothing ties one line of text to one moment.

## What the agent writes

An agent says who it is in `agents/<n>.json`: `{"name": …, "alive": <UTC time>, "url": <optional web address>}`. It takes the first free number from 0, and sets `alive` at each of its checks. The app reads these files by name, from 0 up to the first one that is missing, in the folder and once a minute in the bucket; it lists nothing. The panel shows each agent with its name and when it was last alive, and opens the address on a click if it is `http` or `https`. With no agent file the panel shows "Connect your agent". An agent is shown in grey when the pages changed more than two hours ago and its `alive` is older than that change; an agent with nothing to do is never grey.

Transcripts go to `transcripts/<copy>/p<N>.md`, in the bucket for an agent of the bucket and in `~/OpenSmartPen` for an agent on the Mac. Not under `books/`: that is the app's side, and an agent that sweeps for changed files would otherwise be woken by its own output.

The app shows them. When a page is open in the viewer with the transcript pane on (the button in the bar, or T), the app fetches that one file by name, shows it beside the ink, and asks again every 30 seconds while the pane is open. Each transcript fetched is kept at the same path under `~/OpenSmartPen`, so it can be read offline. With no bucket connected, the pane shows the file in the folder. With a bucket connected, the bucket's transcript replaces the one in the folder, so use one agent for one page, not two. The path is therefore part of the contract: move the transcripts and the pane goes empty. The key needs permission to read as well as to write.

The pane draws Markdown a line at a time: `# ` as the title, `## ` as a heading (the agent uses it for when a part was written and which meeting it belongs to), `- ` as a bullet, and emphasis and `~~struck~~` inside a line. Line breaks are kept as written. Anything else is shown as plain text.

## Open

- Grouping pages into notes. Candidates: same book plus a time gap (Neo Studio 2 uses 15 minutes), or a hand-drawn marker in a page corner.
- Whether `pens/`, `mode.jsonl` and `palette.json` should go up at all while the only agent transcribes from the PNG.

## The setup text for a new agent

`docs/agent-install.md` is what a new agent sets itself up from. The website serves a copy at `https://opensmartpen.org/agent-install.md`, and `https://opensmartpen.org/llms.txt` is the door: it tells an agent where it is (folder or bucket), how the person gets the app, and to read the setup text. The copy is made by hand: after a change, copy the file to `public/agent-install.md` in the `web` repository and publish it. The text carries the same version number as `last-modified.txt`: change the rules, and raise both.

The app puts no instructions in the folder or in the bucket. The folder and the bucket hold data: pages, transcripts and the agents' own small files.

An agent is started in one of two ways, both in the panel under "Connect your agent". Each way gives the agent the same sentence, which points at `llms.txt` and says where the pages are:

- **Set up a new agent.** The app offers what it finds on the Mac. "Claude Code", when the `claude` command is installed, opens the Terminal in the notes folder and starts Claude Code there with the sentence. "Claude Cowork", when Claude Desktop is installed, opens a Cowork task with the folder and the sentence typed. Claude Code is marked as recommended, because it can run a check each minute that costs nothing; Cowork wakes on its own schedule, hourly at the shortest.
- **Use an agent you have.** "Copy instructions" copies the sentence. This is the way for every other agent, and for one in the cloud.

## The instructions given to the agent

Sent 2026-11-11, before `last-modified.txt` existed, so they say to trigger on the PNG. That still works. An agent that should use the time file must be told about it. `<BUCKET>` and `<PREFIX>` were filled in. They name a marker file to ignore. The app wrote one when a bucket was connected, until 2026-11-15; it writes none now. A bucket connected before then can still hold the old file, and it is not a note.

```
My smart pen writes to S3 bucket <BUCKET>, folder <PREFIX>. Add it to the sweep.

Layout (the Mac app only writes here; it never reads or deletes):
  books/<copy>/book.json        notebook title, paper size, first_page
  books/<copy>/raw/p<N>.jsonl   strokes of one page
  books/<copy>/pages/p<N>.png   image of that page
  pens/<slug>.json              pen names
  mode.jsonl, palette.json      ink colour data (already drawn into the PNG)
Ignore opensmartpen-connected.txt and the folder books/s3-o1013-b1-* (a control strip, not notes).

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
