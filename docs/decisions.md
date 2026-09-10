# Decisions

Running log. Newest at the bottom. Each entry: what was decided, why, what it rules out.

## 2026-09-10 — Hardware

- Pen: **Neo smartpen A1** (NWP-F151), Bluetooth 5.0, 160 A4 pages offline memory, C1 gel refill 0.5 mm.
- Paper: NeoLAB **Ncode A4** bundle (NC-P0081E) and **LAMY digital paper** (NC-P0198E). Both are NeoLAB notebooks (Ncode owner 27).
- Consequence: page geometry for these two books must come from NeoLAB's `.nproj` data or be measured from strokes. See `docs/stroke-format.md`.

## 2026-09-10 — Client is macOS, not iOS

- Near-time is enough: a page should be digitised within ~10 minutes of the last stroke. No live streaming to a phone.
- Build a **macOS app** on iOS-SDK3.0 (`NISDK3`, Swift, targets macOS 10.13+). It connects when the pen is in range, drains offline memory, and receives live dots when the pen is used at the desk.
- Rules out: iOS app, background Bluetooth on a phone, App Store distribution (also sidesteps the GPL distribution question for now).

## 2026-09-10 — Storage and processing

- **Source of truth is the raw dot stream**, one append-only JSONL file per physical page. SVG and PNG are derived. Markdown transcription is derived.
- **GitHub-backed.** The Mac app commits raw pages; the processing side commits derived files. DAM integration is deferred; the agent will be always-on when it comes, so wake semantics do not matter.
- Debounce lives in the client: a page is "quiet" after N minutes without strokes (default 10), then it is published for processing.

## 2026-09-10 — Transcription

- Try both: stroke-based recognition (Google ML Kit Digital Ink, on-device, Czech supported) and image-based (Claude on the rendered PNG). The user already photographs notes into Claude Code with good results, so image-based is the baseline.

## 2026-09-10 — Note grouping

- Open. The pen's unit is the page. Grouping pages into notes is a derived index; keep a log of how other products do it in `docs/landscape-log.md` and decide once real data exists.
