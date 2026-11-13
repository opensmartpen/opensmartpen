# Stroke format (source of truth)

One file per physical page, append-only JSON Lines. Each physical *copy* of a notebook is one
folder under `~/OpenSmartPen/books`, named by the surface identity the client reported and an id the
app generated (ADR-002); a page file sits in that copy's `raw/`, named as the client named the page:

```
books/s3-o27-b450-7f3a9c/raw/p12.jsonl
```

A book code identifies a product, not a copy — two identical A4 pads report the same
`s3/o27/b450` — so the folder, not the address, is what finds a file.

## Records

Each line is one JSON object with a `t` type field. Strokes are the unit of capture; a stroke is pen-down to pen-up.

```jsonc
{"t":"stroke","id":"<uuid>","start":1757530000123,"end":1757530000987,
 "tip":"pen","color":"#000000",
 "dots":[[x,y,force,dt,tiltX,tiltY,twist], ...],
 "client":"pen","src":"live|offline","pen":"<mac>","fw":"1.03"}
```

- `x`, `y`: Ncode cells as floats (int part + 0.01 × fraction, exactly what the SDK returns). Never pre-scaled to mm or pixels.
- `force`: 0…1 normalised by the SDK.
- `dt`: milliseconds since the previous dot (first dot 0). Absolute time = `start` + cumulative `dt`.
- `tiltX`, `tiltY`: 0…180 degrees; `twist`: 0…359. Present on A1 firmware; write `null` when absent.
- `client`: which client produced the event (ADR-001). Always `pen` on a stroke: the pen is the only client that senses a surface, so it is the only one that can make one.
- `src`: how the stroke *reached* us — `live` (received while connected) or `offline` (drained from pen memory). Not the same question as `client`: both kinds were made by the pen.

Lines are appended in arrival order, which is not chronological: strokes written in the seconds before a Bluetooth connection completes arrive as `offline` after the first `live` strokes. Consumers must sort by `start`.

Every raw file opens with a header line, written when the file is created:

```jsonc
{"t":"meta","v":1,"captured":1757530001000,"app":"opensmartpen-mac/0.2.0","sdk":"NISDK3/1.1.5"}
```

- `v`: the format version. ADR-001 commits to the sequence of values in a dot, so anything that changes that sequence — or the meaning of a field already written — raises this number. A reader that meets a version it does not know should stop rather than guess.
- `app`: the build that created the file. The header is not an event, so it carries no `client`.

Files created before the header existed have none, and files created by an older build keep the header they were given. Nothing rewrites a raw file.

## Settings: `mode.jsonl`

An ink colour or a line width is chosen, not written, so it belongs to no page. Each line records only the field that changed, at the moment it changed:

```jsonc
{"t":"mode","at":1757530000123,"ink":"red","client":"pen","tap":"<stroke uuid>"}
{"t":"mode","at":1757530002456,"width":"thick","client":"app"}
```

- `client`: `pen` for a tap on the paper controller, `app` for a click in the panel.
- `tap`: the control-surface stroke the tap was decoded from, so the change can be traced to its evidence in raw. Only a paper tap has one.

The file is not in time order — a tap made away from the Mac is drained hours later — so a reader replays the events by `at` to get the state in force at any moment. Lines written before 2026-09-14 say `src`: `paper` is `pen`, `panel` is `app`.

## Why not SVG or InkML as source

- SVG loses pressure, timing and page identity unless stuffed into attributes, and appending requires rewriting the file.
- InkML is the right standard but verbose and XML; nothing in our stack needs it. We can emit InkML from JSONL later if a recogniser wants it.
- JSONL appends atomically per stroke and diffs cleanly in git.

## Geometry (needed only for rendering)

Ncode cell = 2.371 mm. A4 is ~88.6 × 125.3 cells; A5 (LAMY digital paper) ~62.4 × 88.6 cells. Each notebook's page rectangle and margins live in an `.nproj` XML (`<page_item number x1 y1 x2 y2 crop_margin="l,r,t,b"/>`). NeoLAB publishes only sample files; the Web SDK fetches `.nproj` for a given (section, owner, book) from NeoLAB's Firebase storage, which is the first thing to try for our two books. Fallback: measure min/max over the first pages written and assume standard paper size.

A copy's own `book.json` records its paper size when we know it, so rendering is reproducible.

## Derived files

Beside the captured files, inside the same copy, carrying the same page name:

```
books/s3-o27-b450-7f3a9c/pages/p12.svg   # rendered strokes, pressure → width
books/s3-o27-b450-7f3a9c/pages/p12.png   # raster for vision models
books/s3-o27-b450-7f3a9c/pages/p12.md    # transcription + frontmatter
```

The number a person counts to lives in `book.json` and in the transcription's frontmatter. It does
not name a file, so `raw/p12.jsonl` and `pages/p12.svg` pair by eye.

Everything in `pages/` can be deleted and made again. Nothing in `raw/` can. Derived files are
regenerated from the record and are never edited by hand.
