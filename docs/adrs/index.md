# ADR Index

Hand-maintained in this repo (no generator). Add a row when you create or supersede a record.

## Accepted

| ID | Title | Supersedes | Subsystem | Summary |
| --- | --- | --- | --- | --- |
| 001 | [Raw stroke log per page is the source of truth](001-raw-strokes-source-of-truth.md) |  | stroke-format | Every page is an append-only JSON Lines file of raw pen dots in Ncode cells; SVG, PNG and text are derived and regenerable. |
| 002 | [A macOS bridge publishes raw pages to git; processing happens elsewhere](002-mac-bridge-publishes-to-git.md) |  | architecture | Capture is a thin, autonomous macOS menubar app that commits quiet pages to a GitHub repo; rendering and transcription run in a DAM agent off that repo. |

## Proposed

| File | Title | Subsystem | Summary |
| --- | --- | --- | --- |
