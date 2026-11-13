# Smart pen → digital notes: research and design critique

Date: 2026-09-10. Sources: NeoSmartpen GitHub org (13 repos, READMEs, PDFs, source), neolab.net, App Store, plus web research on the wider field. Items marked *unverified* were not confirmed against a primary source.

## 1. What exists today from NeoLAB

### SDKs (github.com/NeoSmartpen)

| Repo | Lang | Last push | License | Verdict |
|---|---|---|---|---|
| iOS-SDK3.0 (`NISDK3`) | Swift | 2026-04 (tag 1.1.5) | GPL-3.0 or commercial | **Use this.** Pure Swift source over CoreBluetooth, iOS 10+ **and macOS 10.13+**, CocoaPods + SPM, no app key. |
| WEB-SDK2.0 (`web_pen_sdk`) | TS | 2026-03 (npm 0.8.0 is 2024-11) | GPL-3.0 | Web Bluetooth, Chrome/Edge desktop only. Good for a no-Xcode prototype. |
| Android-SDK2.0 | Java | 2026-06 | GPL-3.0 | Active. |
| Windows-SDK2.0 | C# | 2026-06 | GPL-3.0 | Repo active, NuGet stale (2020). |
| IOS-SDK2.0 | Obj-C | code 2020 | GPL-3.0 | Superseded. |
| Ncode-SDK2.0 | C++/C# | 2023 | commercial | Generates Ncode patterns. Closed binaries, test key only. |
| Documentations | PDFs | 2020 | none | Ncode dev guide, `.nproj` spec, `.neonotes` format. BT protocol v1 PDFs deleted but recoverable from git history; v2 only by email. |
| UWP-SDK, Ncode-SDK, IOS-SDK, IOS-Sample, neolab-data-platform | | 2018–2023 | | Stale or archived. |

Not in the org: any renderer library, any Ncode PDF generator for end users, any Python/BLE implementation, any "NeoInkSDK".

### iOS SDK 3.0 essentials

- Delegate API: `PenDelegate.penData(_:_ dot: Dot)`, `penMessage`, `hoverData`. UIKit-era, trivially wrapped in an `ObservableObject`.
- `Dot`: `x, y` (Ncode cells, float), `force` 0…1, `nTimeDelta` ms, `xtilt/ytilt/twist`, `pageInfo{section, owner, note, page}`, `dotType` Down/Move/Up, `penTipType`, `penTipColor`, `time` ms epoch.
- You must call `requestUsingAllNote()` after connect or no dots arrive.
- Offline memory: `requestOfflineNoteList`, `requestOfflinePageList`, `requestOfflineData(section, owner, note, pages, deleteOnFinished)`, progress messages. Sample: `Example/NISDK3/PenOfflineNoteViewController.swift`.
- Rendering needs page geometry from `.nproj` (`Example/…/NProjParser.swift`, `ScaleHelper.swift`). Only a few sample nproj files ship (books 234, 261). NeoLAB's own notebooks are owner 27 and their tables are not published; home-printed Ncode PDFs have known A4/Letter geometry.
- Pens supported: N2 (F120/F121), M1 (F50), M1+ (F51), Dimo (F30), LAMY Safari (F80), A1 (F151), R1 (F40).

### Bluetooth protocol v2 (if you ever want your own client)

- GATT: 16-bit service `0x19F1`, write `0x2BA0`, notify `0x2BA1`; 128-bit variant service `4F99F138-9D53-5BFA-9E50-B147491AFE68`.
- Framing `0xC0 | cmd | [err] | len(LE u16) | payload | 0xC1`, escape `0x7D` XOR `0x20`.
- Commands: 0x01 version, 0x02 password, 0x04 settings, 0x11 online-data (using-note list), events 0x63 pen up/down, 0x64 paper info, 0x65 dot (13 bytes: dt u8, force u16, x u16, y u16, fx u8, fy u8, tiltx, tilty, twist u16), 0x6C dot with event counter, 0x6F hover; 0x21–0x25 offline list/pages/data/ack/delete.
- Fully readable in `NISDK3/Classes/Common/Global.swift`, `PenCommParser.swift` and `WEB-SDK2.0/src/PenCotroller/{CMD,PenClientParserV2}.ts`.

### Ncode

- Cell = 2.371 mm (56 px at 600 dpi). `inch = ncode * 56 / 600`.
- Each cell encodes section, owner, book, page, x, y. Section 3 is normal notebooks (owner 10 b, book 13 b, page 9 b, x/y 10 b).
- Print your own: free Ncode PDFs from neolab.net (A4/Letter, 50 pages each). Colour laser ≥600 dpi, PostScript driver; inkjet not supported.
- Community: `GregorR/pyncode` (2026-07) overlays the free template patterns onto your own PDFs.

### Community projects worth reading first

- `JoshGJPI/smartpen-logseq-bridge` (2026-08) and `JoshGJPI/neosmart-pen-explorer` (2025, live site): Web Bluetooth, browse and back up offline pen data without erasing, raw JSON export.
- `AlfredJKwack/PenStrokeKit` (MIT, 2026-08): local-first Chrome app on `web_pen_sdk`, IndexedDB, canvas.
- `mrtzpngrtz/airsketch` (2026-01): Electron + `web_pen_sdk` 0.8.0.
- `StudioProcess/NeoSmartpenMac` (2020): macOS port of SDK 2.0 with WebSocket forwarder.
- `aalexei/python-neosmartpen` (2019): parses `.neonotes` backup zips to PDF. No Bluetooth.

## 2. NeoLAB's own apps

- **Neo Notes** (2014–2020): service terminated Dec 2020. Used **MyScript** for handwriting recognition, 34 languages, exported SVG/PDF/TXT/DOCX, synced to Evernote/OneNote/Drive.
- **Neo Studio** (2020–2024): manual sync at most every 15 min via the user's Google Drive. Appears delisted (*unverified*).
- **Neo Studio 2** (Mar 2024, current): iOS 16+, Android 10+, web app. Free, no IAP. Real-time automatic sync to **NeoLAB's own cloud** (not iCloud, not your Drive). Exports per page: video, PDF, PNG, **SVG**, web URL. "Text Extraction" in 35 languages with downloadable packs (engine undisclosed, MyScript likely, *unverified*). Google Calendar push from planner pages. **No API, webhooks, folders, Zapier, Notion or Obsidian integration.** App Store rating 1.8★ from ~20 reviews, dominated by sync failures and ink not appearing.
- **PaperTube**: lecture video recorder, last update 2022, abandoned.
- Company: active, but 2024–2026 launches are kids' AI pens (POKORO) and edtech (AiGLE). No new consumer pen since A1/R1 in 2024.

### Pens on sale (Sept 2026)

| Model | Price | Offline memory | BT | Refill |
|---|---|---|---|---|
| M1+ (F51) | $129 | 1,000 A4 pages | 4.2 | D1 |
| A1 (F151) | $139 | 160 A4 pages | 5.0 | proprietary C1 |
| LAMY Safari Ncode (F80) | $169 | not published | 4.3 | D1 |
| R1 (F40) | $89 | 20 A4 pages | 4.2 | |
| Dimo (F30) | $59 | ~3–20 pages (*conflicting*) | | |

N2 and M1 are discontinued.

## 3. The wider field

- **Pens**: Anoto/Livescribe launched **inq** in 2025 (Echo 2 sold out); Moleskine Pen+ is NeoLAB hardware; **Nuwa Pen** (plain paper, 3 cameras, $299) shipped beta 2025 with no credible independent review; **Wacom** killed Bamboo Slate/Folio apps Dec 2025 and its device SDK, keeping only WILL 3 and the Universal Ink Model; XP-Pen Note Plus ($89) has a buggy app; Rocketbook OCR is English only.
- **Stroke (online) HWR engines**: MyScript iink (contract pricing, used by reMarkable, Supernote, Nebo); **Google ML Kit Digital Ink Recognition** (free, on-device, iOS and Android, 300+ languages incl. Czech and Slovak); Azure Ink Recognizer retired 2021; no production-grade open-source stroke recogniser.
- **Image OCR**: Apple Vision has 18 locales, **no Czech**; TrOCR ~2.9% CER on IAM; Tesseract ~12%.
- **LLM vision on handwriting** (2025–2026 benchmarks): Claude Opus 4.7 ~1.3% CER, GPT-5 ~1.2%, Gemini 3 ~1.4% on IAM; **6–12% CER on messy handwriting**; ~$12–15 per 1,000 pages for frontier models. The failure mode is confident hallucination (filling gaps, "fixing" spelling), not blanks. Peer-reviewed: arXiv 2503.15195.
- **Stroke to SVG / notes to Markdown tooling**: rich for reMarkable (`rmc`, `remarks`, `rmapi-hwr`) and Supernote (`supernote-tool`); nothing maintained for Neo. Formats: W3C InkML, Wacom UIM, vendor JSON, SVG with per-path metadata.
- **LLM OCR to Markdown pipelines**: `lucbeaulieu/claude-ocr-pipeline` (watched folder → Claude → Markdown + Reminders, 2026-03), Obsidian plugins `handwrite-obsidian` and `HandTranscriptMd` (Gemini).

## 4. Critique of the proposed design

Proposed: iOS app ↔ pen over Bluetooth → an agent workspace holding one SVG per note plus one OCR file produced by Claude Code, regenerated with a debounce on every raw-file change.

1. **The pen buffers; real-time is optional.** M1+ holds 1,000 pages. Sync-on-desk via the offline download API covers the "digitise my notes" goal with zero background-Bluetooth work. Real-time only matters if you want text while still writing.
2. **The iOS app is the most expensive piece and may be unnecessary.** iOS-SDK3.0 also targets macOS. A Mac menubar app, or the Web SDK in Chrome, gives the same stroke stream with no signing, no background-mode limits. Build iOS last, if at all.
3. **SVG is a render, not a source.** Keep the raw dot stream (section/owner/book/page, x, y, force, dt, tilt) as the source of truth in an append-only JSONL or InkML file per page. Derive SVG, and derive PNG for the OCR step, since Claude reads images, not SVG paths. Appending to an SVG on every stroke is awkward; appending a JSONL line is natural.
4. **The unit is the page, not the note.** Every dot carries a page id. Define note = group of pages by notebook and time gap (Neo Studio 2 uses 15 min) as a derived index, not as the storage unit.
5. **Page geometry is a real gap.** Rendering needs the notebook's `.nproj` bounds. Home-printed Ncode PDFs are known geometry; bought notebooks (owner 27) are not published. Plan to infer bounds from the data or fetch nproj through the Web SDK's Firebase path.
6. **The debounce must live in the client.** A hosted agent has no trigger for a changed file, so the client decides when a page is quiet and sends it.
7. **The agent is the OCR worker, not the archive.** Keep strokes, SVG and Markdown somewhere that outlives the agent.
8. **Use stroke recognition before image OCR.** Google ML Kit Digital Ink runs free and on-device with Czech support and uses the actual strokes, which beats image OCR on messy writing. Claude then cleans, structures and cross-checks against the PNG. Expect 6–12% character error on rushed handwriting and watch for confident hallucination; keep the image next to the text.
9. **Debounce policy.** Re-transcribing a page on every stroke burst multiplies cost and drift. Transcribe when a page has been quiet for minutes, on page switch, or on pen sleep.
10. **License.** iOS-SDK3.0 is GPL-3.0. Private use is fine; distributing the app (TestFlight included) means open-sourcing it or paying NeoLAB roughly $7,000 per year (2023 figure).
11. **Paper supply is a lock-in.** Ncode notebooks or a colour laser printer at 600 dpi. Inkjet does not work.
12. **Which pen?** Decides offline capacity, Bluetooth version and refill. M1+ (1,000 pages, D1 refills) fits the sync-on-desk model best; A1 has BT 5.0 but 160 pages and a proprietary refill.

## 5. Suggested phasing

- **Phase 0, no pen**: define the stroke JSONL schema, write the stroke → SVG → PNG renderer with synthetic data, build the transcription step (render, ML Kit or Claude transcription) and verify one run end to end.
- **Phase 1, pen arrives**: connect via `web_pen_sdk` in Chrome or a small macOS Swift tool, download offline pages, run the OCR. Validate geometry and accuracy on real handwriting.
- **Phase 2**: macOS menubar app for automatic sync when the pen is in range. Only then decide whether iOS real-time is worth it.
