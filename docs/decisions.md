# Decisions

Running log. Newest at the bottom. Each entry: what was decided, why, what it rules out.

## 2026-09-10 — Hardware

- Pen: **Neo smartpen A1** (NWP-F151), Bluetooth 5.0, 160 A4 pages offline memory, C1 gel refill 0.5 mm.
- Paper: NeoLAB **Ncode A4** bundle (NC-P0081E) and **LAMY digital paper** (NC-P0198E). Measured 2026-09-11: A4 pad is s3/o27/b450, LAMY paper is s3/o1012/b3017 (not owner 27; LAMY has its own owner code).
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

## 2026-09-10 — Responsibilities (late evening clarification)

- PenBridge only keeps raw files current in git. Fully autonomous: auto-connect, auto-drain, commit and push, delete from pen after push. Notifies the person only on problems.
- All rendering and transcription happens in DAM, off the git repo. Recorded as ADR-002; ADR-001 records the raw-log-as-source-of-truth decision.

## 2026-09-11 — First contact with the A1

- End to end worked on the first attempt: pair, authorise, drain (12 offline strokes), delete from pen, live strokes, reconnect in 2 s after a restart.
- Found and fixed: pending pages lived only in memory, so a restart stranded a written-but-uncommitted page. PenBridge now adopts every uncommitted raw file on startup, dated by its modification time.
- Pen colour for live strokes arrives as 0xFFFFFF ("unset"); stored as black.
- Notes repo stays local for now (`~/PenBridge/notes`, no remote); the user does not want it on GitHub yet.
- Later: pen auto power-off is 5 min and auto power-on is off. Keep the defaults for now; add config options to set both from PenBridge.
- LAMY digital paper is owner 1012, book 3017 (not owner 27). Owner codes belong to the paper brand, not the pen maker.
- The stroke in progress when a Bluetooth connection completes arrives twice, from memory and live, with ~23 ms clock offset. The store now drops a stroke matching an existing one on the same page (dot count, first and last dot, start within 500 ms).
- Ncode identity is section/owner/book/page, and the pen's memory and delete commands are per book (notebook), so a drain is naturally a batch of pages from one physical notebook.
- Timestamps: every stroke carries absolute start/end in epoch ms and every dot a millisecond delta (median 12 ms, roughly 80-120 dots/s), so writing can be replayed exactly. PenBridge sets the pen clock on each connect; strokes buffered before a pen's first ever connect may carry an unsynced clock, so treat absolute times on the first drain with suspicion while relative timing stays sound.
- Observed: dedupe fired on real data (`dropped duplicate offline stroke ... on s3/o1012/b3017/p5`).
- Ink colour is a pen *setting*, not something the pen senses. Swapping a physical refill changes nothing in the data; every stroke arrives stamped with whatever colour the pen currently holds (black by default). If colour is ever wanted, PenBridge has to tell the pen which colour to stamp, e.g. from a menu.
- Pen factory defaults observed on the A1: auto-off 5 min, auto-power-on-by-tip Off, cap-power-off Off, offline-save On, hover Off, beep Off. Auto-power-on is now set to On by PenBridge; settings are read back once after a write so a refused write shows up in the log.
- The printed colour strip is its own Ncode identity, s3/o1013/b1, separate from the notebook it ships with (LAMY is s3/o1012/b3017). A tap on it was being filed as a note page. PenBridge now treats configured `controlBooks` as commands: taps are logged with their coordinates and never stored. Interpreting which swatch was tapped needs either the notebook's `.nproj` symbol table (`<symbols><symbol cmdParam=...>`) or an empirically built coordinate map.
- The A1 refuses `auto-power-on` over Bluetooth: the write is accepted silently but a read-back shows the pen kept Off. Removed from the config so PenBridge stops asking. The pen must be woken by its button; a five-minute sleep therefore stays a real way to lose strokes.
- PenBridge is installed as a LaunchAgent (`com.apoco.penbridge`), started at login and restarted on exit, from `~/Applications/PenBridge.app`, logging to `~/Library/Logs/PenBridge/penbridge.log`.
- Notebook geometry, resolved 2026-09-11 without NeoLAB: A4 pad (book 450) is 210 x 297 mm; LAMY digital paper (book 3017) is 145 x 210 mm, 192 pages, dot ruled, slightly narrower than A5. Recorded in `geometry/` in the notes repo. The Paperhub API would give this authoritatively but needs NeoLAB credentials.
- Rendering works end to end: `pipeline/render.py` produces legible SVG and PNG from raw dots with no calibration needed.
- Ncode page numbers are not the printed page numbers: the LAMY notebook's first written sheet reported as page 4. Never show raw Ncode page numbers to the user.
