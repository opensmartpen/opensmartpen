# Stroke format (source of truth)

One file per physical page, append-only JSON Lines, path derived from the Ncode page identity:

```
raw/s{section}/o{owner}/b{book}/p{page}.jsonl
```

Example for a NeoLAB A4 page: `raw/s3/o27/b<book>/p12.jsonl`.

## Records

Each line is one JSON object with a `t` type field. Strokes are the unit of capture; a stroke is pen-down to pen-up.

```jsonc
{"t":"stroke","id":"<uuid>","start":1757530000123,"end":1757530000987,
 "tip":"pen","color":"#000000",
 "dots":[[x,y,force,dt,tiltX,tiltY,twist], ...],
 "src":"live|offline","pen":"<mac>","fw":"1.03"}
```

- `x`, `y`: Ncode cells as floats (int part + 0.01 × fraction, exactly what the SDK returns). Never pre-scaled to mm or pixels.
- `force`: 0…1 normalised by the SDK.
- `dt`: milliseconds since the previous dot (first dot 0). Absolute time = `start` + cumulative `dt`.
- `tiltX`, `tiltY`: 0…180 degrees; `twist`: 0…359. Present on A1 firmware; write `null` when absent.
- `src`: `live` (received while connected) or `offline` (drained from pen memory).

Optional metadata records:

```jsonc
{"t":"meta","captured":1757530001000,"client":"penbridge-mac/0.1","sdk":"NISDK3/1.1.5"}
```

## Why not SVG or InkML as source

- SVG loses pressure, timing and page identity unless stuffed into attributes, and appending requires rewriting the file.
- InkML is the right standard but verbose and XML; nothing in our stack needs it. We can emit InkML from JSONL later if a recogniser wants it.
- JSONL appends atomically per stroke and diffs cleanly in git.

## Geometry (needed only for rendering)

Ncode cell = 2.371 mm. A4 is ~88.6 × 125.3 cells; A5 (LAMY digital paper) ~62.4 × 88.6 cells. Each notebook's page rectangle and margins live in an `.nproj` XML (`<page_item number x1 y1 x2 y2 crop_margin="l,r,t,b"/>`). NeoLAB publishes only sample files; the Web SDK fetches `.nproj` for a given (section, owner, book) from NeoLAB's Firebase storage, which is the first thing to try for our two books. Fallback: measure min/max over the first pages written and assume standard paper size.

Store discovered geometry in `geometry/s{section}-o{owner}-b{book}.json` so rendering is reproducible.

## Derived files

```
pages/s3/o27/b<book>/p12.svg    # rendered strokes, pressure → width
pages/s3/o27/b<book>/p12.png    # raster for vision models
pages/s3/o27/b<book>/p12.md     # transcription + frontmatter (page id, timestamps, confidence)
```

Derived files are regenerated from raw and are never edited by hand.
