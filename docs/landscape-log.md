# Landscape log: how others do it, how we differ

Append as we learn. One row per product feature we care about. "Ours" is updated as we decide.

| Concern | Neo Studio 2 (NeoLAB) | reMarkable | Supernote | Livescribe / inq | Rocketbook | Ours |
|---|---|---|---|---|---|---|
| Capture unit | Page keyed by Ncode (section/owner/book/page) | Page in a notebook document | Page in a `.note` file | Page keyed by Anoto pattern | Photo of a page | Page keyed by Ncode, raw dots kept |
| Sync trigger | Real-time over BT, auto to NeoLAB cloud; offline buffer drained on reconnect | Wi-Fi, on change, to reMarkable cloud (Connect subscription) | Wi-Fi/USB, to Supernote cloud or Drive/Dropbox | BT to app, then Evernote/OneNote/Drive | Manual scan | BT to Mac when in range; page quiet 10 min → publish |
| Note grouping | Notebook = physical book; "Separate overlapping handwriting" splits a page by time gap ≥15 min | Notebook = document you create on device | Notebook = file you create | Notebook = physical book | Page destination chosen by ticking a symbol | Open; candidates: physical book + time gap, or a hand-drawn marker on the page |
| Storage owner | NeoLAB cloud only | Vendor cloud | Vendor or user cloud | Vendor + third-party | Third-party (Drive, Notion, etc.) | User's GitHub repo |
| Vector format | SVG export per page/notebook | `.rm` v6 binary; community `rmc` → SVG | `.note`; community `supernote-tool` → SVG | Proprietary; PDF export | None (raster) | JSONL dots (source) + SVG (derived) |
| Handwriting to text | "Text Extraction" button, 35 language packs, engine undisclosed (MyScript in the predecessor) | MyScript, needs Connect | MyScript on-device | MyScript historically; inq says "AI" | OCR, English only | ML Kit strokes and/or Claude on PNG; Czech required |
| Automation / API | None | Community API (`rmapi`) | Community tools | None | Destinations only | Everything is files in git; agents run on top |
| Search | Keyword, tag, notebook | Full-text after conversion | Keyword | Keyword | Smart titles | Markdown in git; grep and agent |
| Audio | Voice memos linked to strokes | No | No | Core feature (Echo) | No | Not planned |

## Notes

- 2026-09-10: Neo Studio 2's 15-minute time-gap split is the only vendor heuristic we found for turning a page into notes without the user doing anything. Worth copying as the default, then improving with content.
- 2026-09-10: Rocketbook's "tick a symbol to route the page" is the only zero-UI routing gesture we found. A pen-drawn marker in a page corner (e.g. a boxed letter) could route pages to projects. Cheap to detect from strokes.
