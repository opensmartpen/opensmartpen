# ADR Index

Hand-maintained in this repo (no generator). Add a row when you create or supersede a record.

## Accepted

| ID | Title | Supersedes | Summary |
| --- | --- | --- | --- |
| 001 | [Keep all captured data, and make the readable files from it](001-keep-captured-data.md) |  | Every event is recorded as it occurs — a stroke, a setting or a command — and never changed. The readable files are made from that record, and can be made again at any time. |
| 002 | [Each copy of a notebook is one folder, named by an id we generate](002-one-folder-per-notebook.md) |  | A stroke is filed under the surface identity its client reported; each physical copy of a notebook gets one folder with a generated id, holding its record, its captured pages and its readable files; a setting has no surface, so all settings go to one file in time order. |
| 003 | [The UI is a layer of its own, and design fixtures ship in nothing](003-ui-layer-separate-from-the-pen-sdk.md) |  | The macOS app splits into BrainioPenCore, BrainioPenUI (every view, no pen SDK, reaching the pen only through a PenLink protocol) and the app itself; the design window and its fixtures live in a separate executable that nothing else can import. |
| 004 | [A page moves only when it is finished, and a buffer empties only on confirmation](004-quiet-pages-and-safe-handoff.md) |  | A page is published only after it has been quiet for a set window, a notebook is deleted from pen memory only after that publish confirms, and what is still outstanding is read back from the stored files rather than from anything the app remembers. |
| 005 | [A macOS menubar app owns the pen](005-mac-app-owns-the-pen.md) |  | Capture is a thin, unattended macOS menubar app that is the only thing that talks to the pen; it writes raw pages and does no rendering, recognition or transcription. |

## Proposed

| File | Title | Summary |
| --- | --- | --- |
| [DRAFT-new-copy.md](DRAFT-new-copy.md) | When in doubt, a new copy | Two signals decide whether a notebook is a new copy — a sequence restart and ink overlap — and a long silence alone never decides; when the signals disagree we choose the new copy, because a wrong split is visible and repairable while a wrong merge is neither. |
| [DRAFT-dots-to-strokes.md](DRAFT-dots-to-strokes.md) | Dots become strokes at capture, and duplicates are matched by content | The dot stream is cut into strokes on the pen-up the SDK reports; a stroke carries absolute start and end plus per-dot deltas, and a stroke delivered twice across a reconnect is recognised by its dots rather than by an id. |
| [DRAFT-mode-event-log.md](DRAFT-mode-event-log.md) | Ink and width are our state, kept as an event log | The pen cannot be told an ink colour, so colour and line width are state on the Mac, recorded as an append-only log of changes stamped with each tap's own time; a return to defaults is derived from the gap between strokes and never written. |
| [DRAFT-image-transcription.md](DRAFT-image-transcription.md) | Transcription reads the rendered image, and a page can carry commands | A page becomes text by rendering it and asking Claude to read the image, with the image kept beside the text as evidence; a line the writer opens with a command marker is transcribed as a task whose progress survives re-transcription. |
| [DRAFT-git-is-a-view.md](DRAFT-git-is-a-view.md) | Git is a view on the notes, not a step in the flow | The notes repository stays on this Mac with no remote; a page is safely held the moment its file is written, a commit only shows a person what changed, and both the pen erase and the outstanding list read the files instead of git. |
