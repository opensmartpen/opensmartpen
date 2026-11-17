# Decisions

Running log. Newest at the bottom. Measurements, incidents, dead ends, open questions and ideas.

A decision leaves this log the moment an accepted ADR holds it — the ADR keeps the reasoning, and `docs/adrs/index.md` is the list. Drafts do not count.

## 2026-09-10 — Hardware

- Pen: **Neo smartpen A1** (NWP-F151), Bluetooth 5.0, 160 A4 pages offline memory, C1 gel refill 0.5 mm.
- Paper: NeoLAB **Ncode A4** bundle (NC-P0081E) and **LAMY digital paper** (NC-P0198E). Measured 2026-09-11: A4 pad is s3/o27/b450, LAMY paper is s3/o1012/b3017 (not owner 27; LAMY has its own owner code).
- Consequence: page geometry for these two books must come from NeoLAB's `.nproj` data or be measured from strokes. See `docs/stroke-format.md`.

## 2026-09-10 — Transcription

- Try both: stroke-based recognition (Google ML Kit Digital Ink, on-device, Czech supported) and image-based (Claude on the rendered PNG). The user already photographs notes into Claude Code with good results, so image-based is the baseline.

## 2026-09-10 — Note grouping

- Open. The pen's unit is the page. Grouping pages into notes is a derived index; keep a log of how other products do it in `docs/landscape-log.md` and decide once real data exists.

## 2026-09-11 — First contact with the A1

- End to end worked on the first attempt: pair, authorise, drain (12 offline strokes), delete from pen, live strokes, reconnect in 2 s after a restart.
- Pen colour for live strokes arrives as 0xFFFFFF ("unset"); stored as black.
- Later: pen auto power-off is 5 min and auto power-on is off. Keep the defaults for now; add config options to set both from Open Smart Pen.
- LAMY digital paper is owner 1012, book 3017 (not owner 27). Owner codes belong to the paper brand, not the pen maker.
- The stroke in progress when a Bluetooth connection completes arrives twice, from memory and live, with ~23 ms clock offset. The store now drops a stroke matching an existing one on the same page (dot count, first and last dot, start within 500 ms).
- Ncode identity is section/owner/book/page, and the pen's memory and delete commands are per book (notebook), so a drain is naturally a batch of pages from one physical notebook.
- Timestamps: every stroke carries absolute start/end in epoch ms and every dot a millisecond delta (median 12 ms, roughly 80-120 dots/s), so writing can be replayed exactly. Open Smart Pen sets the pen clock on each connect; strokes buffered before a pen's first ever connect may carry an unsynced clock, so treat absolute times on the first drain with suspicion while relative timing stays sound.
- Observed: dedupe fired on real data (`dropped duplicate offline stroke ... on s3/o1012/b3017/p5`).
- Ink colour is a pen *setting*, not something the pen senses. Swapping a physical refill changes nothing in the data; every stroke arrives stamped with whatever colour the pen currently holds (black by default). If colour is ever wanted, Open Smart Pen has to tell the pen which colour to stamp, e.g. from a menu.
- Pen factory defaults observed on the A1: auto-off 5 min, auto-power-on-by-tip Off, cap-power-off Off, offline-save On, hover Off, beep Off. Auto-power-on is now set to On by Open Smart Pen; settings are read back once after a write so a refused write shows up in the log.
- The printed colour strip is its own Ncode identity, s3/o1013/b1, separate from the notebook it ships with (LAMY is s3/o1012/b3017). A tap on it was being filed as a note page. Open Smart Pen now treats configured `controlBooks` as commands: taps are logged with their coordinates and never stored. Interpreting which swatch was tapped needs either the notebook's `.nproj` symbol table (`<symbols><symbol cmdParam=...>`) or an empirically built coordinate map.
- The A1 refuses `auto-power-on` over Bluetooth: the write is accepted silently but a read-back shows the pen kept Off. Removed from the config so Open Smart Pen stops asking. The pen must be woken by its button; a five-minute sleep therefore stays a real way to lose strokes.
- Notebook geometry, resolved 2026-09-11 without NeoLAB: A4 pad (book 450) is 210 x 297 mm; LAMY digital paper (book 3017) is 145 x 210 mm, 192 pages, dot ruled, slightly narrower than A5. Recorded in `geometry/` in the notes repo. The Paperhub API would give this authoritatively but needs NeoLAB credentials.
- Rendering works end to end: `pipeline/render.py` produces legible SVG and PNG from raw dots with no calibration needed.
- Ncode page numbers are not the printed page numbers: the LAMY notebook's first written sheet reported as page 4. Never show raw Ncode page numbers to the user.
- Transcription is `pipeline/transcribe.py`, calling the local `claude` CLI so it needs no API key. Output is Markdown with frontmatter naming the page, stroke count, write times, model and source image, and a standing warning to check the image.
- PNGs are rasterised directly from the strokes with Pillow, not converted from the SVG. macOS Quick Look silently dropped strokes: page 1 rendered without its "Hello", and three different models all "transcribed" the page faithfully from that broken image. A rendering bug is indistinguishable from an OCR failure downstream, which is the argument for keeping the image beside the text.
- The PNG is cropped to the written area; the SVG keeps the true page. A line of writing marooned in an A4 of white space transcribes badly.
- Commands: a line the writer opens with `>>` is transcribed as `- [ ] >> instruction`. The executing side marks it `[·]` while running and `[x]` when done. Because the Markdown is derived and the paper cannot be un-written, transcription carries previous states forward by matching normalised command text; without that, every re-transcription would offer finished commands as new work.
- LAMY page numbers are left alone (`first_page: 1`). The notebook has specially formatted sheets at the front, so its Ncode page numbers are the physical page numbers, not an offset to correct. `first_page` stays available for a notebook that genuinely starts elsewhere.

## 2026-09-11 — Idea: name the book from the interface

- Open. The plumbing already exists: `books/<slug>.json` carries `title`, and Open Smart Pen's `BookRegistry` reloads when those files change, so a rename shows up in the panel without a restart. What is missing is only a way to type the name — today it means finding the file and editing JSON. Same gap as [naming the pen](#2026-09-11--idea-name-the-pen), and worth solving once for both.
- **The real question is slug versus title, and they are not the same rename.** `title` is display only and free to change at any time. The slug is the filename and it also names the derived directory (`pages/a4-pad/`), so changing it moves every rendered page, every transcription, and the paths in any note that links to them. A naming UI that quietly renames the slug would rewrite history; one that never does leaves you with `pages/a4-pad/` under a notebook you now call something else.
- Suggested split: let the title be edited freely, and treat the slug as set once when the book record is first created — derived from the title then, and changed afterwards only by an explicit, separate action that moves the directory and says so. Cheap to decide now, expensive to retrofit once there are notes pointing at page paths.
- Worth doing at the same moment a book is first seen. Open Smart Pen already knows when a page arrives from an Ncode book with no record in `books/`, which is exactly when a person knows what the notebook is — it is sitting in front of them. Asking then beats asking never.

## 2026-09-11 — Idea: name the pen

- Open, not started. The panel shows whatever the SDK reports as the device name. A pen should carry a name its owner chose, stored beside its MAC the way `notebooks` stores a name beside a book key — the same shape of problem, solved the same way.
- It stops being cosmetic the moment there is more than one pen: a role needs a label, and "Highlighter" or "Red" in the panel and in notifications is the difference between a readable app and a list of MAC addresses. Prerequisite for [three pens, three roles](#2026-09-11--idea-three-pens-three-roles) being usable rather than merely possible.
- Cheap either way, because `Stroke.penMac` already identifies the pen in raw. Naming is a derived-side lookup and changes nothing about what is captured.

## 2026-09-11 — Idea: three pens, three roles

- Open, not started. Keep three A1s instead of one: a default black, a second colour, and a highlighter. You choose a mark by picking up a pen, rather than by tapping a mode onto the one pen you own.
- **The raw format already supports it.** Every stroke carries `"pen":"<mac>"` (see `docs/stroke-format.md`), so which physical pen made a mark is recorded today and needs no format change. The role is a lookup from MAC to meaning on the derived side, which keeps raw honest: it says which pen wrote the stroke, not what we decided that means.
- **It is better than the control strip, not just easier.** The strip's `black` / `red` / `highlighter` / `pen` buttons need a coordinate map we do not have — the one tap captured did not land in any rectangle from `note_3_1013_1.nproj`. Worse, a mode is invisible once set: the paper cannot tell you which mode you were in, so a wrong stamp is silent and permanent. A pen in your hand is self-evident, and the role is attached to the hardware rather than to a setting that can drift.
- **Highlighter is a derived interpretation, not a captured one.** The SDK's `PenTipType` is `Normal` or `Eraser` only; no pen can report "this is a highlight". So you underline, and processing renders that stroke as a translucent band instead of a line. Raw keeps the underline, because an underline is what the pen actually saw — the same split as ADR-001. Simplest first version is a band over the stroke's own bounding box, thickened upward; making it cover *the line above* needs text geometry from the transcription step, not strokes alone.
- **The cost falls on Open Smart Pen, which today pairs exactly one pen.** `penMac`/`penPeripheralId` are single values and `matches()` rejects everything else, so this needs a list of known pens and a role beside each. Open question: whether NISDK3 will hold more than one connection at a time — `PenFinder.shared` looks built around a single controller. Possibly moot, since the A1 sleeps after five minutes and only one pen is in your hand at a time; connecting to whichever is awake, with offline memory covering the others, may be enough.
- Ink colour would still be worth setting per pen on connect so the stamped colour matches the refill actually in the barrel, but that is cosmetic: the role map decides rendering, so the feature works even if the stamp is wrong.
- Cost to weigh: three batteries to keep charged, three pens that can be asleep when you reach for them, and three drain queues on reconnect.

## Known issue: a second notebook of the same kind will collide

Ncode section 3 gives 13 bits of book code, 8192 per owner, so a book code identifies a **product**, not a physical copy. Two identical A4 pads therefore report the same section, owner and book, and their page 1s are the same address. Writing in a fresh pad would append to the previous pad's page files.

This does not affect the two notebooks in use today, which differ. It bites the first time a notebook is replaced with another of the same kind.

The intended fix keeps raw capture untouched, because mixed strokes are what the pen actually reported and the file should stay honest. A notebook record gains **instances**, each a slug plus the date it was started, and the derived layer routes each stroke to an instance by its timestamp. `pages/a4-pad-2/` fills up while `pages/a4-pad-1/` stays frozen. Nothing in Open Smart Pen changes.

**The decision can be made late.** Every stroke already carries an absolute timestamp and raw capture is append-only per page, so a boundary date can be applied retroactively at any point and everything downstream re-derives. Getting the date wrong is a re-render, not a loss.

**Detection should suggest, never decide.** At the moment it happens, a new notebook and a return to annotate an old page are indistinguishable: both are fresh strokes on a page that already has ink after a long gap. Two signals beat time alone — a *sequence restart* (ink appears at the front and marches forward, which revisiting does not do) and *ink overlap* (new strokes crossing existing ones cannot be the same sheet, though deliberate underlining and crossing out look the same). When both line up with a gap of weeks, notify and ask; a wrong silent guess merges two notebooks into one file and would go unnoticed.

Not built: there is nothing to test it against until a second notebook of the same kind exists.

## 2026-09-12 — The paper controller, and how thick a line should be

- **Our line was twice as thick as NeoLAB's.** Neo Studio exports a page as PDF, where each stroke is a *filled outline* rather than a stroked path, so the file carries no width value; measuring 509 strokes as `2 × area ÷ perimeter` gives 0.29 mm for its default ink. We were drawing 0.57 mm. `NIB_MM` is now 0.25, which reaches 0.29 mm once pressure widens it, and `render.py --nib` overrides it.
- **The LAMY paper controller is decoded.** It is Ncode book `s3/o1013/b1` and it is ordinary paper: 13 buttons, three line widths at x ≈ 9.8 cells (y 46.3 / 52.9 / 60.1) and ten colour swatches in two columns at x ≈ 20.0 and x ≈ 15.9, rows y 43.9 / 48.3 / 53.2 / 57.8 / 62.4. Taps are matched to the nearest column then the nearest row, not to a printed rectangle, so the left column's estimated position and the two extrapolated rows still land correctly; a tap far from every button is refused rather than snapped. The eight-button map in `note_3_1013_1.nproj` describes a different product and is abandoned — the September tap that "landed in no rectangle" was the red swatch.
- **The pen does not act on the strip at all.** Every stroke came back `#000000` however many swatches were tapped, and NISDK3 has no ink colour command — only `requestSetPenLEDColor`, for the LED. So ink colour and line width are our state on the Mac, not the pen's, confirming rather than overturning the earlier finding that colour is a setting rather than something sensed. The LED can mirror the choice as an acknowledgement, but not as an indicator: the A1 sleeps after five minutes and the LED dies with it.
- **Mode changes are an event log, not a current value.** `mode.jsonl`, one line per change, timestamped with the tap's own time. A current value cannot work: a tap made away from the Mac waits in pen memory and arrives at the next drain, so a whole morning's pages would render in whatever colour was selected by the evening.
- **Each line records only what changed.** Full state per event was the first design and it is wrong for the same reason: events are appended in arrival order, not time order, so a line written at 18:05 cannot know about a tap made at 09:20 that has not drained yet, and would claim a width that was never in force. A change is true whenever it is written down. Readers replay in timestamp order.
- **Returning to the defaults is derived, never written.** After a long enough silence, writing resumes at the pen's defaults. The boundary is computed from the gap between consecutive strokes across the whole repo — not per page, since turning a page is not a reset — so nothing has to be recorded and no third writer exists. Two corrections found while building it: the boundary must censor the event replay rather than gate a single stroke, or the next stroke finds last week's colour and un-resets itself; and taps count as writing for the gap, or tapping red after a week away puts the boundary *after* the tap and silently discards the choice.
- **The pen's own power-off is evidence, never input.** Open Smart Pen logs it, and it is what identified the reset boundary (two power cycles, two resets to black, no timer needed). It must not be joined on: we only hear it while connected, so a pen that sleeps in a bag reports nothing, and a derived file that depends on what was observed rather than on what was written is no longer reproducible (ADR-001). The gap is worse at describing the pen and better as a rule.
- **The control book is the first case where derived is a deliberate subset of raw.** The tap is stored — the pen saw it, so raw says so — but it never enters the tracker, so it starts no publish countdown and never appears in the panel as an unclickable notebook; and `pages/` gets nothing, since asking a vision model to read six dots is not a page. It rides the next publish rather than triggering one. Until now derived was simply a regeneration of raw; this is the first place the two diverge on purpose.
- **Hex values and widths live in `palette.json` in the notes repo**, not in code, so the panel and the renderer cannot disagree about what `red` looks like. Ten ink names; black, red, blue and green measured from the Neo export, five estimated at the user's request (the printed swatch is markedly duller than the ink it selects, so the strip cannot be used to measure them), and white left null.
- **White is a dead button.** Tapping it is logged and stored, and selects nothing, because what it means is undecided. A button that does nothing is easier to explain than one that silently renders a page in an ink nobody measured.
- **Open: how long the silence has to be.** Neo appears to reset in minutes, but both observed resets followed a power cycle, so a timer is not needed to explain either. The discriminating test is to write, wait three minutes without touching the pen (under the five-minute auto-off), and write again. Also open: whether matching Neo is even wanted, since a colour that cannot survive a phone call is barely worth choosing.
- **Also open: 1.89 mm for the thick setting** destroys legibility at the size these notes are written. Neo does the same, so we are faithful rather than broken, but the number may have been measured from a page where that setting was not being used deliberately.
- **A raw page file can hold two physical notebooks, so rendering splits it.** A book code identifies a product, not a copy, so a second pad of the same kind writes to the same addresses. `books/<slug>.json` may carry `instances` — a slug and the moment writing in that copy began — and a stroke belongs to the last instance that started at or before it. Each copy gets its own directory under `pages/` rather than overwriting the last one's. A record without the array behaves exactly as before, which is both current notebooks.
- **Writing resumes at the pen's own defaults, not at a constant.** `pens/<slug>.json` carries `ink` and `width`, every stroke already records which pen made it, and the gap rule returns there. A pen kept for accents is not a black pen that someone keeps re-selecting. MAC matching is case-folded with separators stripped, so a hand-written record need not match the pen's formatting.

## 2026-09-12 — Identifiers, the bundle and the icon

- **The capture app's directory is `app/`, not `OpenSmartPen/`.** Inside a repo already called `opensmartpen`, an `OpenSmartPen/OpenSmartPen/Sources/OpenSmartPen` path says the name three times and locates nothing. `app/` names the component by its role, which is what `pipeline/` and `docs/` already do.
- **Identifiers are `OpenSmartPen`; anything a person reads says "Open Smart Pen".** Targets and the log directory are one word; notification titles, tooltips, window titles, the Info.plist display name and the bundle's own filename take the space. The binary and the slugs are `opensmartpen`.
- **Changing the bundle id costs both TCC grants.** macOS keys Bluetooth and notification permission to the bundle identifier, so the first launch under `org.opensmartpen.app` asks for both again, and the pen does not connect until Bluetooth is granted. Saved window positions reset with it. Unavoidable, and the reason the installer prints it.
- **Bluetooth permission is only ever offered to a copy launched from the Finder.** An app started by launchd never sees the prompt: `CBCentralManager.authorization` stays `notDetermined` and the agent waits forever for a radio that is already switched on. The grant is keyed to the code signature as well as the bundle id, and an ad-hoc signature changes with every build, so it is needed again after each rebuild — the price of not having a Developer ID.
- **The Finder launch has to come before the agent is bootstrapped, not after.** `open` on a bundle that is already running only activates the running copy: it starts no process and raises no prompt. So an installer that starts the agent and *then* says "open it once from the Finder" is giving advice that cannot work — the first version of this did exactly that, and it is the same failure the diagnosis above was written to catch. `install-launchagent.sh` now boots out, installs, opens, waits for the person, and bootstraps last.
- **"Bluetooth is off" and "we were never allowed to use it" are different faults with opposite fixes.** NISDK3 collapses both into one `bluetoothOn` flag and logs the difference only to its own console, which cost an hour of looking at a switched-on radio. `PenSession.bluetoothProblem()` now reads `CBCentralManager.authorization` and says which one it is, and what to do.
- **The app icon is the menubar pencil**, drawn by `scripts/make-icon.swift` from the same path and the same 16-unit grid as `StatusIcon.pencil`, so the two cannot drift apart unnoticed. It carries no ink drop: the drop means pages are waiting to sync, and an icon has no business claiming a state. The `.icns` is generated, not committed, like every other derived artefact here.
- **The bundle is `Open Smart Pen.app`, with the space.** macOS shows the bundle's filename in the Bluetooth and Notifications permission lists rather than `CFBundleDisplayName`, so an `OpenSmartPen.app` reads as "OpenSmartPen" in exactly the places a person goes to check what has access to their pen. Identifiers keep the closed-up form.
- **A fault has to outlive one scan tick before it is announced.** CoreBluetooth reports `.unknown` for a fraction of a second after launch, before settling on powered-on, so the first version of the diagnosis above declared "Bluetooth is switched off" on every single start — about a radio that was fine, observed live on 2026-09-12. A confident wrong answer at startup is precisely what the diagnosis was written to prevent, so the complaint now waits five seconds. A real fault outlives that easily; a wakeup never does.
- **The app icon is the notebook, not the pencil.** A pencil is what every note app puts on its icon and says nothing about this one; the panel's own `PaperMark` — the page, the elastic at 0.72 of the width, the ink dot on the corner — is already the mark this app is recognised by. `PaperMark`'s proportions are kept exactly and its stroke weight is not: a 1-in-11 line is right at 13 px and reads as a fat letter at 1024, so the glyph is drawn larger and lighter.
- **The panel is 252 points wide: three pen tiles and the pin, and no more.** Three is as many pens as are plausibly in use at once, and a width reserved for a hypothetical fourth is too wide every day for a case that never arrives. A fourth tile still fits the row, sliding under the pin, which is the right way round for something that rare. The design window gained a `threePens` scenario at the same time — a measurement nobody can look at goes wrong unnoticed.
- **The notebook marks are traced from the design, not approximated from it.** The panel drew a pad as a bare rounded rectangle, when the drawing gives it a glued head — a heavier line a third of the way down — which is the entire difference between "a pad" and "a box"; and it ran the bound book's elastic past the covers, which the drawing does not. `PaperMark` now carries the drawing's own numbers on its own 16-unit grid (bound: rect 2.5,2 by 10x12, r1.6, stroke 1.1, elastic at x 10.6 from y 2 to 14; pad: rect 3,2.5 by 10x11, r1.2, stroke 1.1, head at y 5.1 across the full width, stroke 1.6), so the two can be checked by reading them side by side.
- **The mark no longer varies by paper shape.** The design has exactly two glyphs, keyed to binding, and a third axis invented in code is a third way to disagree with it. `RecentBook.shape` went with it rather than staying as a field nothing reads.
- **The app icon is traced from the same numbers**, with one deliberate exception: the 1.1 stroke is thinned to 0.75. A line weight is right at 15 points and wrong blown up 70 times, so copying it would match the drawing and miss the drawing's intent.
- **The dot on the app icon sits on the cover's corner, not where the panel puts it.** In the panel it is a badge hung clear of a 15-point row-mark so it cannot be read as part of the book; copied faithfully to 1024 it reads as a dot floating loose in the plate. Centred on the corner and nudged 0.6 units out, it belongs to the notebook — dead centre and it eats the head of the elastic, which turns the whole thing into a pin stuck in a page.
- **`actool` must compile somewhere of its own.** Pointed straight at `Resources/`, it writes its own `AppIcon.icns` containing only the handful of sizes it thinks are needed, on top of the ten-size one `iconutil` produces. That is how the icon silently became 256 px. The catalog is compiled into a staging directory, only `Assets.car` is taken, and the `.icns` is written last.
- **Open: notification banners show a blank icon.** The bundle carries a ten-size `AppIcon.icns`, a compiled `Assets.car`, and both `CFBundleIconFile` and `CFBundleIconName`; `NSWorkspace` and Finder resolve the icon correctly. The banner is still a grey placeholder, identically whether the app is started by launchd or from the Finder, and after a full `lsregister -u`, delete, reinstall, `lsregister -f` and `killall usernoted` — so it is neither a stale LaunchServices record nor a notification-daemon cache. The remaining suspect is the ad-hoc signature: no Team ID, nothing for the daemon to attribute the app to. A Developer ID would settle it, and there is nothing further worth trying without one.

## 2026-09-12 — the git boundary withdrawn, and what that cost

- **A withdrawn decision leaves no record behind.** The app-owns-the-pen record's git boundary was removed rather than deprecated, because nothing had been built on it that survived. The consequence to watch: `docs/processing.md` still describes an input shape, and no ADR now backs it.
- **An accepted body was edited in place, against the ADR rule.** Both records were two days old, single-author and uncommitted to anyone else; supersession would have spent two records on deleting clauses from decisions that had not themselves changed. Recorded here so the exception is visible rather than silent.

## 2026-09-14 — Idea: cluster writing by time, and a post-processing agent

- **Open, worth experimenting with.** A page is not one sitting. You write in a notebook during a meeting, come back in the afternoon and write more on the same sheet, and the two have nothing to do with each other. Grouping by page is grouping by paper, which is a property of the notebook rather than of the thinking.
- **Cluster by the gap between strokes.** Every stroke already carries an absolute start time, so the clustering is derived and can be redone at any moment with a different threshold — the same property that lets an instance boundary be applied late. Show the clusters in the preview, and let each one be exported on its own.
- **The mechanism already exists for another purpose.** `reset_boundaries` in `pipeline/render.py` computes gaps between consecutive strokes across the whole repo, to decide when ink returns to the pen's defaults. That is the same computation at a different threshold, on the same timeline.
- **This is a candidate definition of a note.** The glossary calls a note "a user-meaningful grouping of pages (by book, time gap, or marker), derived and not yet defined". Time-gap clustering answers it, with one difference worth keeping: a cluster can be *part* of a page, not only a run of pages. So a note is a set of strokes, not a set of sheets.
- **The route is a post-processing agent, not more code in the app.** The pages get read by a model anyway for transcription. The same pass can propose the cluster boundaries and pull out the commands written on the page.
- **It extracts commands and runs nothing.** Deliberately: the risky half of a command is the doing, and an agent that only proposes has no blast radius. It is also the cheapest way to learn what people actually write before deciding how a command fires — see the open question about which commands may run unattended.
- **What the experiment answers:** whether a gap threshold matches how sittings actually feel, whether one threshold works or it has to adapt, and what a person really writes when they mean to instruct.

## 2026-09-14 — How these records are kept

- **An ADR states what it decides *and* what it does not.** ADR-001 kept acquiring claims that were never its business — a path scheme, a per-page rule, a geometry source. It now carries a `Boundaries` section naming the record that owns each. Worth copying into the other records.
- **Third in-place edit of an accepted body, still against the rule.** Same reasoning as 2026-09-12. Three rounds on one record is the evidence that ADR-001 was accepted before it had been read properly — the review now under way exists to stop that happening to 002, 003 and 004.
- **A decision leaves this log once an accepted ADR holds it.** The ADR keeps the reasoning; this log keeps only what no ADR records — measurements, incidents, dead ends, open questions and ideas. Drafts do not count: a proposed record is not decided, so its material stays here until it is accepted.
- **Open: where page geometry comes from.** No record claims it. `.nproj` is unparsed and its Firebase source turned out to be your own bucket, not NeoLAB's, so measurement is the only path that runs today. `BookRecord` already holds `widthMM`/`heightMM`, so the gap is authority, not storage: what wins when a measured size, an `.nproj` and a typed-in size disagree.

## 2026-09-14 — ADR-001 read against the code

- **The record now says which format version it is in.** ADR-001 commits to raising a format version if the sequence of values in a dot changes, and there was no version to raise. Every raw file — a page and the mode log — now opens with `{"t":"meta","v":1,…}`. Files that already exist keep the header they have, or none: nothing rewrites a raw file to suit a newer reader.
- **`client` means one thing, and `src` means one thing.** A stroke said `src:"live|offline"` and a mode change said `src:"paper|panel"` — the same key answering two different questions, and neither of them "which client produced this", which is what ADR-001 asks every event to record. Now every event carries `client`: `pen` or `app`. `src` is left to the strokes, where it says how one reached us, not who made it.
- **A paper tap is still told apart from a panel click**, by `tap`, which only a paper tap has — it points at the control-surface stroke the change was decoded from. So collapsing `paper|panel` into `pen|app` loses nothing, and the file header stops claiming to be an event: it names the build that wrote the file (`app`), not a client.
- **An interrupted write cost two records, not one.** Appending sought to the end and wrote. A process killed mid-line leaves a file with no final newline, so the next stroke was written onto the broken line and both became unreadable. Raw files are now appended through `AppendOnlyFile`, which puts the missing newline back first. The broken line stays where it is: it is evidence, and the record is never rewritten.
- **Open: commands are not events.** ADR-001 makes a command the third kind of event in the record, and nothing writes one. Commands are found on the derived side, as `>>` lines read out of the transcription, and each one's done-state lives in the `.md` file that gets regenerated — so the readable file is the first and only place holding that fact, which the record forbids. This is the same ground as the post-processing agent idea above; it needs a record of its own before it is built.
- **A pen's default ink stays outside the record, deliberately.** `pens/<slug>.json` says what a pen writes with when nothing has been chosen. It is a property of a pen, not an event that happened, and editing it changes how past pages render — which is the point when a pen is re-purposed. ADR-001 leaves "which pen or notebook a setting applies to" out of scope, and it stays there.
- **The pen-up dot is not dropped data.** NISDK3 sends the last Move sample again with `dotType = .Up` to mark the pen leaving the paper. Storing it would put the same position in the stroke twice with a non-zero `dt`, which reads as the pen resting there. It is kept whenever it actually moved, so no measurement is discarded — only a repeat of one.

## 2026-09-14 — ADR-002 read against the code

- **Git stays, as a way to see what changed.** The repository was the destination for captured files, and ADR-002 moves them to `~/OpenSmartPen`. Git keeps only its second use: a diff says which files a drain or a render touched, and a commit gives a point to go back to. It is a view on the data, not the place the data lives, and nothing reads a page out of it.
- **The app decides a new copy on its own.** ADR-002 says we never ask. `InstanceWatcher` only made a question, and the panel put it to the person. Both are gone. `CopyWatcher` returns the signal that decided, `PageRouter` acts on it before a stroke is written, and the new copy announces itself by turning up in the panel as a second book.
- **A new copy is decided before the stroke is written, not after.** Routing has to come first: a stroke written into the wrong copy interleaves two notebooks inside one captured file, and separating them would mean cutting a file we never cut. So `PageRouter.route` runs, and only then `RawStore.append`.
- **Ink overlap is asked as a grid, not as a bounding box.** Two pages written full always overlap as boxes, and so do a page of notes and one line added in its margin. The question that tells those apart is whether the new dots land *where the old dots are*, so ink is bucketed into one-cell squares and the answer is the share of arriving dots that land in an occupied square. A quarter is the threshold — well above annotating, well below writing the same sheet twice.
- **`first_page` no longer names a file.** A readable page now carries the same name as the captured one it came from, so `raw/p4.jsonl` becomes `pages/p4.svg` and the two pair by eye. The number a person counts to is still in `book.json`, and still what the panel and a transcription's frontmatter show — the LAMY pad's `p4` is page 1 to read, and `p4` on disk.
- **Open: what moves a page between copies.** ADR-002 promises a wrong guess is repaired by moving pages, and nothing moves them yet. Until a tool exists, the repair is `mv` and an edit to `book.json`. `DRAFT-new-copy` names this as uncovered too.

## 2026-09-14 — Nothing is pushed

- **The notes repo has no remote, and `gitPush` now defaults to off.** Backing the pages up to GitHub is not wanted yet. The default said the opposite, so every install started by asking for a remote it was never going to get, and reported the missing one as a fault.
- **Git keeps both of its local jobs.** A commit is still the mark that says a page is finished, and `git status` is still the list of what is written but not yet finished — which is what ADR-004 asks for, and what lets a restart pick up a stranded page. Neither needs a remote.
- **Nothing else moved.** The publish flow, the quiet window, the backoff and the rule that a notebook leaves pen memory only after its publish confirms are unchanged; "publish" now means "commit". `GitPublisher` was left whole rather than cut down, because turning backups on later is then a setting, not a rewrite.
- **The no-remote notice was already conditional on `gitPush`**, so it went quiet by itself. With pushing on and no `origin`, it still fires once and pushing stays off for that run.
- **Incident: one A4 pad became five, then two hundred.** The rule now lives in `DRAFT-new-copy`; what belongs here is what went wrong. First, a re-delivered stroke read as a second notebook. The pen sends the same writing twice — live and again from memory, and a whole notebook again when a drain is retried — and a re-sent stroke lands on its own ink exactly. Overlap was measured before `RawStore` dropped the duplicates, so every drain looked like a fresh pad written over the old one. One A4 pad became five on this Mac within a day. The order is now: ask the store what it does not already hold, and judge only that. The duplicates still travel on to the store, which drops them there — filtering them in the router would make it the second place that decides what a duplicate is. Second, and worse, the question was asked of every arriving stroke, so ordinary handwriting answered yes: two hundred strokes on one page made two hundred copies.

## 2026-09-14 — Three faults found while building

- **The page was drawn upside down, and only the agent noticed.** Core Graphics counts y up from the bottom; paper and every dot the pen reports count it down from the top. The first reading came back with a note that the image was mirrored top to bottom. Handwriting flipped about its own line still looks like handwriting, which is why nothing else caught it. There is now a test that renders a page heavy at the top and fails when the halves swap — checked by removing the flip and watching it fail.
- **Every rebuild costs the Bluetooth grant.** A new ad-hoc signature loses the Bluetooth (TCC) grant, so the app must be opened by hand once after each build. A stable signing identity ends it; see `scripts/make-signing-identity.sh`.
- **`make-app.sh` said "built" after a failed build**, because the build's exit status was thrown away and a stale binary in `.build/release` was packaged instead. It cost half an hour of testing an old app. The status is now checked, and `install-launchagent.sh` refuses a bundle older than `Sources/`.

## 2026-09-15 — The page picture is drawn for an agent

- **The page is drawn for the agent now, not for a person.** 1100 to 1568 pixels on the long side, where `render.py` uses 700 to 2200. A model scales anything longer than about 1568 back down, so more is bytes spent on nothing; under about 1100 the agent starts magnifying. This is a deliberate parting from `render.py`, whose PNG is opened in Preview by a person.
- **A menubar-only app has no editing keys.** ⌘A, ⌘C and ⌘V are key equivalents of Edit-menu items, and an accessory app has no menu bar, so the settings fields could be typed into but not copied out of or pasted into. There is now a main menu that nobody sees, holding Edit and a Close item.

## 2026-09-15 — The design was being done blind, and now it is not

Every panel until this point was written, packaged, installed, and then judged by somebody else looking at it. The strip beside the sheets was defensible in code and bad on screen, and there was no step between those two facts.

- **`scripts/shot.sh` takes a picture of the app's own windows**, by window id through CoreGraphics, one PNG each. Nothing else on the screen is in the frame, which matters when it is somebody else's desktop. `--show-actions` opens the actions window on a row with a conversation in it, because a script cannot click a menubar item and the shut row and the open row are two different designs.
- **What one look found, in one pass:** an empty agent bubble rendering as a grey void; a title bar with nothing in it above a heading that said the same word; two lines of grey caption under every row; a finished line repeating its last sentence under itself; no boundary around the row that was open; and no heading above the pile of finished ones. Six faults, none of which were visible from the code.
- **An empty reply is now a sentence**, not an empty card. A turn can end with the agent saying nothing — it writes only the status line, or stops — and the thread says so in words.
- **The window draws its own header.** Borderless, with the title, the count and the close button on one line, rounded down the side that faces the work and square against the screen edge. A docked column has no use for minimise or zoom.
- **A bug the screenshot found by accident:** the agent roster had vanished from the config. Two objects each held a whole copy of it and wrote it back — pairing a pen quietly threw away everything typed into the settings window since that copy was made. `PenSession` now re-reads the file and writes back only the two fields it owns.

## 2026-09-16 — Retest of the A1 power settings, firmware 3.00

- Reported: the pen does not wake when the tip is pressed, and notes written away from the Mac are lost. One cause, not two. The pen slept after 5 min and nothing on the page can wake it, so strokes written afterwards were never captured. The log shows every offline drain in four days succeeded, and tonight's drain pulled 154 strokes on 5 pages intact — nothing was lost in sync. The loss is only ever strokes the pen never recorded.
- Retested all three power writes, one per connection, each proved by the read-back in `applyPowerSettings`:
  - `AutoPowerOffTime` 5 → 120 min: **accepted**. Read-back shows 120, and it survived a disconnect and reconnect — the pen stores it.
  - `AutoPowerOn` (wake on tip press): the pen says accepted, the read-back keeps Off. Refused, as recorded on 2026-09-11, and still refused on fw 3.00.
  - `PenCapOff`: the same silent refusal. The A1 has a cap; it controls nothing.
- The 2026-09-11 conclusion "a five-minute sleep therefore stays a real way to lose strokes" rested on an assumption the test disproved: a refusal of one power command says nothing about another. They are separate commands (`AutoPowerOffTime = 2`, `AutoPowerOn = 4`) and the pen treats them differently.
- Live config now has `penAutoPowerOffMinutes: 120`. The button is the only wake path on this pen. Open: the firmware's ceiling for the timeout (UInt16 on the wire, untested above 120), and whether two idle hours cost battery worth caring about.
- Harness note: a freshly started app instance failed to find the awake pen for 2.5 min, while a restart found it in 8 s. Not chased. Scanning was silent because `Log.debug` is gated on `OPENSMARTPEN_VERBOSE=1`, an environment variable the LaunchAgent does not set — there is no config key for it.

## 2026-09-16 — The menubar pencil says whether a pen is connected

- Asked for: the menubar icon should tell a connected pen from one that is not. Until now `StatusIcon.make` knew pages waiting, battery and whether Bluetooth was usable — nothing about the link. A sleeping pen and a connected one drew the same mark.
- First try was a filled shaft for "connected". Rejected while looking at it in the design window: a solid area in the strip's grey tint read as *dimmed*, the opposite of what it meant, and it added a second look to learn. The strip itself was also lying — a bare `NSImageView` draws template marks in a grey tint while the one non-template mark (red battery) drew at full strength; fixed with `contentTintColor = .labelColor` so the strip shows the marks as the menubar does.
- Decided: **one rule — dim means no pen is talking to this Mac, full means one is.** Asleep, out of reach and Bluetooth off all look the same; the tooltip says which. This reverses the earlier reasoning that dimming was reserved for "cannot work" because a sleeping A1 would leave the menubar faint most of the day. It will, and that is the honest picture: with the 5-minute sleep back, most of the day there is no pen to talk to.
- Low battery is never dimmed — a warning does not fade.

## 2026-10-07 — Several pens, added in Settings

- Asked for: pair a second pen. The app kept one paired pen (`penMac`) and ignored every other pen. The UI already drew one tile per pen in `pens/`, so only the session and the config were single-pen.
- **Every paired pen connects at the same time.** `PenSession` now finds pens and decides which to keep; a new `PenConnection` holds one linked pen — auth, drain, strokes, battery. The SDK allows this: each link gets its own `PenController`. Connects are made one at a time, because a fresh scan empties the SDK's list of seen pens, and that list is where a pen's MAC comes from when it connects.
- **A new pen is only taken while somebody is adding one.** "Add pen…" in Settings → Pens looks for two minutes and pairs the first unknown pen it sees. With no pen paired at all, the first pen seen is still paired with no setup. "Forget…" unpairs a pen and keeps its `pens/` record.
- **Config:** `pairedPens` is a list. An older config's `penMac` and `penPeripheralId` are read into it and are not written back. The settings window no longer saves its own copy of the list over the session's.
- **Ink mode is still one for all pens.** The colour strip sets the mode for every pen, and the LED shows it on every connected pen. Per-pen modes are not part of this change.
- **Not seen with two pens.** It builds and the tests pass. The new pairing path was not run against hardware.


## 2026-10-08 — Pens are let go before the Mac sleeps

- **Lost:** half a page written in a café on 2026-10-07 with the LAMY, lid shut. Only what was written after the lid was opened arrived. The pen reported 0 books in memory on the next connect, so nothing was waiting to be drained.
- **Cause, from bluetoothd's log:** a sleeping Mac's Bluetooth chip kept the LE link to the pen open (`AP wakeup by LE Data bundleID=org.opensmartpen.app, uuid=<the LAMY>`, several times between 16:13 and 16:17). macOS told the app only that Bluetooth was off, and the app dropped the connection. The pen, still linked, sent the strokes live and stored nothing; they woke the Mac and reached nobody. The A1 shows the same pattern of power-off events on 2026-09-14 and 09-15.
- **Fix:** on `NSWorkspace.willSleepNotification` the session disconnects every pen and stops scanning, and it connects nothing until `didWakeNotification`, so the Mac's background wakes in the night cannot link a pen again before the next sleep. A pen without a link stores what is written, and the drain on wake copies it like any other offline notebook.
- **Not yet proven on hardware:** whether the disconnect always reaches the pen before the Mac is asleep. The check is to write with the lid shut, open it, and find `draining book` in the log.

## 2026-11-11 — The app only captures and uploads

- Removed from the app: actions, transcription, the agent integration with its Settings tab, and git (the local commits as well as the push). The draft records that described them were deleted on 2026-11-13.
- One storage: an S3 bucket, connected in Settings → Sync. A page goes up as its strokes and a PNG once it has been quiet for 30 seconds. One direction only; the app never reads or deletes in the bucket. With no bucket connected, notes stay on this Mac and nothing fails.
- S3 is spoken directly (SigV4 over URLSession, checked against the AWS worked example), not through the AWS SDK. The secret key is in `~/.config/opensmartpen/s3-secret`, not the Keychain. The Keychain ties access to the code signature, and an ad-hoc signature changes with every build, so macOS would ask again after each one.
- What has been uploaded is a list beside the config, not in the notes folder. The existing `.git` in `~/OpenSmartPen` and the old `pages/*.md` and `*.actions.json` files are left where they are; the app no longer reads or writes them.
- Open: what reads the bucket and transcribes. The PNG is the object to trigger on.
- Later the same day: uploads wait on the pen, not on each page — everything pending goes once no pen has reported any event for 30 seconds. And the app reads one thing from the bucket after all: the transcript of the page open in the viewer, at `transcripts/<copy>/p<N>.md`, shown beside the ink. It still makes no transcript itself. The first real one arrived that evening.

## 2026-11-13 — The page picture is kept in the folder

- **Why.** The plan is an open release that works with no bucket (meeting of 2026-11-13). An agent on the Mac had strokes and nothing to look at, because the PNG was drawn at upload only.
- **What changed.** `PagePictures` writes `books/<copy>/pages/p<N>.png` when the pen has been quiet, with or without a bucket. `S3Sync` uploads that file and draws nothing. The folder and the bucket now have one layout, and `docs/processing.md` is one contract for both.
- **The bucket did not change.** Same keys, same order, same moment. The agent of the bucket needs no new instructions.
- **What is owed is read from the files** (ADR-004). A PNG that is missing or older than its strokes makes the page pending at the next start. So the first start of this build draws every page captured before it. The September PNGs made by `pipeline/render.py` are replaced.
- **A retry does not wake an agent.** The file is replaced only when the picture is different.
- **A local agent writes `transcripts/<copy>/p<N>.md` in the folder**, and the viewer already shows it when no bucket is connected. With a bucket, the bucket's transcript replaces the local one.
- Open: the agent kit for a local agent, and what wakes it.

## 2026-11-13 — The source is Apache-2.0, a built app is GPL-3.0

- **Decided:** all source in this repository is Apache-2.0 (`LICENSE`). A built app links NISDK3, which is GPL-3.0, so a built app as a whole is distributed under GPL-3.0. `NOTICE` says which license applies to what.
- **Why this works:** Apache-2.0 code can go into a GPL-3.0 program. The other direction is not permitted. NISDK3 is not in the repository; the Swift package manager downloads it at build time.
- **What NeoLAB wrote:** the SDK's `LICENSE` file and podspec say GPL-3.0. Its README adds "for non-commercial purpose" and offers a commercial license by email. The GPL text permits commercial use and permits no added restriction, so that line is weak in law, but it shows their intent. A question to NeoLAB is open.
- **No Mac App Store.** The App Store terms conflict with GPL-3.0, and only NeoLAB can give an exception. Distribution is a direct download.
- **No contributor agreement.** A contribution comes in as Apache-2.0, and that is sufficient for each later step.
- **Later step, not started: the connector as a separate program.** A helper that links NISDK3 and owns the pen, GPL-3.0; the app without the SDK, Apache-2.0 as a binary too. `Package.swift` already keeps the SDK out of `OpenSmartPenCore` and `OpenSmartPenUI`. Do this when the app must go into a closed product, or when a second pen brand comes.
- **Last option: our own protocol code,** with NISDK3 removed. About 1,000 to 1,500 lines, in the part that must not lose handwriting. Only if the App Store becomes necessary and NeoLAB says no.
- **Checked:** NeoLAB's shop terms, refund policy and FAQ have no term against other software on the pen. The contract for a bulk order was not seen.
- **Open: a built app must carry the license texts and a link to the source.** `make-app.sh` does not put `LICENSE`, `NOTICE` and the GPL-3.0 text in the bundle yet. Necessary before the first public download.
- **Open: the copyright owner.** `NOTICE` says "Apoco", from `NSHumanReadableCopyright`. The legal name of the company is not confirmed.

## 2026-11-13 — A pen is a highlighter or it is not

- **Decided:** a pen's mode is `writing` or `highlight`. `accent` is removed: an ink colour already says it. A pen record that says `accent` is read as `writing`.
- **In Settings:** "Used for" on each pen, with the two choices. The ink dots and the width marks are the same ones as in the panel, on one row.
- **Not done:** nothing draws a highlight differently yet. The PNG is drawn from ink and width only. The mode goes up in `pens/<slug>.json` for an agent that wants it.
- **The settings window is as tall as the tab on it,** up to a limit. It was one fixed size, and most tabs were half empty.

## 2026-11-13 — The project is called Open Smart Pen

- **Decided:** the project, the app and the repository are Open Smart Pen. It is an open project of its own, not a part of another product. The source is at `github.com/opensmartpen/opensmartpen`. The website is `https://opensmartpen.org/` (up since 2026-11-15).
- **One spelling for each use.** Text a person reads: "Open Smart Pen". Swift types and targets: `OpenSmartPen`. Binary, config folder, log file and repository: `opensmartpen`. Bundle id and LaunchAgent label: `org.opensmartpen.app`, the reverse of the domain `opensmartpen.org`. Data folder: `~/OpenSmartPen`.
- **No migration code.** The project starts here, so the app adopts no earlier config folder and copies no earlier notes. An install from before this date is moved by hand, once.
- **The bucket marker is `opensmartpen-connected.txt`** and new raw files carry `"app":"opensmartpen-mac/<version>"`. An agent of the bucket needs the new marker name; see `docs/processing.md`.
- **The log lost some entries.** Entries about features that the app no longer has (the agent integration, actions, the two migrations) were deleted. The repository history has them.
- **An accepted ADR was edited in place.** ADR-002 lost two sentences that gave the earlier product family as the reason for the folder name. The decision itself did not change.
- **Open:** the name promises every smart pen, and the app supports NeoLAB Ncode pens only. The README must say which pens work.

## 2026-11-13 — The company holds the copyright, and outside code needs an agreement

- **Decided:** the copyright line names the company ("Apoco"), not "the authors". The owner wants to be able to change the license later, and only the holder of the copyright can do that for its own code.
- **Outside code needs a contributor agreement before the first merge.** A contributor keeps the copyright on what they wrote. Apache-2.0 lets us ship it under other terms, but a clean change of license needs their permission. `CONTRIBUTING.md` says so.
- **The About tab says "Copyright", not "Made by".** That is what the row is.
- **Open:** the text of the agreement and the tool for it. The legal name of the company is also still open (see above).
- **The root README says which pens work:** the A1 and the LAMY Safari Ncode, the two that were tested.

## 2026-11-13 — The logo is the menubar pencil

- **Decided:** the app icon is the pencil from the menubar, on the same light plate as before. This reverses the 2026-09-12 choice of the notebook. The pencil is the mark a person sees all day, so it is the one that says "this app" in a notification, in the About tab and on GitHub.
- **Same path, one number changed.** `scripts/make-icon.swift` draws the path of `StatusIcon.pencil` on its 16-unit grid. The stroke is 1.0 where the menubar has 1.35, and the ends of the band are cut square; at 1024 pixels a round end shows as a bump outside the outline.
- **No ink drop and no colour.** The drop means pages are waiting, and an icon must not claim a state.
- **One icon file is committed:** `assets/logo.png`, 512 pixels, written by `scripts/make-icon.swift --logo ../assets/logo.png` from `app/`. The README and GitHub need a file; everything else is still generated at build time.
- **A second picture fills the whole square:** `assets/avatar.png`, written by `--avatar`. A GitHub profile frames the picture itself, and the app icon's own margin showed there as a tile inside a tile.
- **The profile picture has its own plate and a bigger pencil.** Near-white, with a violet tint from the top right and a pink one from the bottom left; the pencil is 76% of the square with the menubar stroke of 1.35. It is seen at 20 to 40 pixels, where the app icon's thin pencil was a grey mark. The app icon and the README logo did not change.
- **The README logo has the same look as the profile picture,** on the rounded plate. Only the app icon keeps the plain plate and the thin pencil.

## 2026-11-13 — The files are in fewer places

- **`assets/`** holds the logo and the profile picture. They are brand pictures, not documents.
- **`docs/research.md`** was `RESEARCH.md` at the root. The root now has only what a visitor expects: the README, the license files, and the folders `app/`, `docs/` and `assets/`.
- **`docs/adrs/template.md`** was `docs/adr-template.md`, and **`app/scripts/dev-design.sh`** was `app/dev-design.sh`.
- **`pipeline/` is deleted.** The three Python scripts drew and transcribed pages on the Mac before the app drew the page itself. The app never called them. Older entries in this log still name `render.py` and `transcribe.py`; the repository history has the files.
- **The pencil in every picture is pure black.** It was 13% white.

## 2026-11-14 — One file says the pages changed

- **Why.** The agent is in charge of when it runs; the app starts nothing. An agent that checks often needs a check that costs almost nothing: one small file, not a walk through the folders. A script can also watch one file, and it cannot watch the nested PNG folders.
- **What.** `last-modified.txt` at the top of the folder, and in the bucket. Two lines: when a page picture last changed, and the version of the rules in `docs/processing.md`.
- **Only the time, not the pages.** A list of the last pages is wrong as soon as two sittings pass between two runs of the agent. The files are the truth: a page is owed when its PNG is newer than its transcript.
- **Written last, and only when a picture changed.** After the last PNG of the batch, in the folder and in the bucket. A retry with the same pictures does not move it.
- **Compared with the last value seen, never with a clock.** After a day offline the file arrives with a time that is hours old, which is correct.
- **The bucket got one more file.** The agent of the bucket can ignore it; the instructions it has still work.
- **The agent sets itself up once, and keeps the rules itself.** The door is `https://opensmartpen.org/llms.txt`, and it is the only one: the app's sentence points there. It leads to the setup text, `docs/agent-install.md`, which the website serves as a copy. The copy is made by hand, so the two can drift; the version number in the text is what shows it.
- **An agent says who it is.** `agents/<n>.json`: a name, when it was last alive, an optional address. The panel lists the agents and shows "Connect your agent" when there is none. This replaced a first form built the same day, where a transcript of a fixed file `sample/p1.png` was the proof: that said some agent had worked once, not which one or whether it still does.
- **Grey means behind, not silent.** An agent is grey when the pages changed more than two hours ago and it has not been alive since that change. An idle agent need not spend anything to stay green.
- **A page can be a photo.** The panel files a picture as the next page of one notebook, "Photos". The picture as it arrived is the record; a one-line `.jsonl` names it, so the page is found, sent and drawn by the code that handles a page of strokes. The notebook has a pen-style address that no paper has (`s0/o0/b0`), which is what lets all the notebook code take it unchanged. The viewer shows the picture where it would show ink.
- **The sample is offered, not given.** "Photos" is made when the first picture is filed. Until then the panel has one more entry, "Add Sample Page". A first version filed the sample at the first start; a notebook nobody asked for was clutter. The sample is drawn from a typeface for now, so it proves less than handwriting does.
- **One entry in the panel, "Add Photo…", and one menu at the mouse.** In it: "Choose a File…", "Use the Sample Page" until "Photos" exists, and below them what macOS adds for each iPhone or iPad near the Mac (Continuity Camera: "Take Photo", "Scan Documents", "Add Sketch"). macOS gives a picture back to a view in a window that has the keyboard focus, and hangs its waiting sheet from that window; the window is there and cannot be seen. A picture file can also be dropped on the pen in the menu bar. Two entries in the panel, one for the iPhone and one for a file, were one line too many; a camera tile in the row of pens did not look right beside the pens.
- **What the iPhone sends** (seen 2026-11-14). A photo comes as a JPEG. A scan comes as a PDF whatever kinds the app says it takes, so the app reads the PDF, one page each, at 200 dots to the inch; read the plain way it came out at 72 and 27 MB. macOS decides the entries from the kinds the app takes, and adds them after the menu can be looked at, so an app cannot take one out.
- **The app starts at login, unless that is turned off.** Settings → General, on by default. A pen written with while the app is not running keeps its pages to itself. On a Mac with the developer's LaunchAgent the login item is left alone, because two starters would start two copies and both would take the pen; so this has not run on the Mac it was written on.
- Open: a webhook. An agent could leave an address in its `agents/<n>.json`, and the app would call it after `last-modified.txt` changes, with the same two lines and no page content. It would save an agent in the cloud from polling. It is a notice, not a start: the agent still decides what to do. Against it: the app would call an address written by whoever can write to the bucket, and `AGENTS.md` says the app makes no calls to an agent platform, so that rule would need a new wording first.
- Not done: a general interface for more pens. There is no second pen to test it against, and the Neo SDK is already in three files. For that day, the form we reached: the source adds raw data, reads it back, and says when a page is done with its picture.


## 2026-11-15 — Connecting a bucket writes nothing in it

- **Decided (the owner):** the connection test must only test the connection. It wrote a small file, `opensmartpen-connected.txt`, and a test file in somebody's bucket is litter that every agent then has to be told to ignore.
- **How:** `S3Client.check` asks for a file that the app never writes, and reads how the bucket says no. "No such file" is a pass. "Access denied" is also a pass: the keys are real, and a key that can only write gets that answer. A wrong key, a wrong secret, a wrong region and "no such bucket" fail, each in the bucket's own words.
- **What it gives up:** it does not prove that the key may write. Only a write proves that. A key that may not write shows at the first upload, as a notification.
- **Checked against a real bucket** (an S3-compatible service, not Amazon): right keys pass, a wrong secret is refused with 403, a bucket that is not there is refused.
- **For an agent:** nothing to do. A bucket connected before this date can still hold the old marker file; it is not a note.

## 2026-11-16 — A release is a signed DMG, made from a tag

- **Decided (the owner):** the same shape as the Brainio desktop app: package, verify, publish. The signer is Brainsoft s.r.o. (team `WDDLH339C8`), with the Developer ID that signs the Brainio desktop app. macOS names Brainsoft s.r.o. as the developer of the app.
- **The repository is public, so the credentials are in a GitHub environment, `release`, that accepts only `v*` tags.** A pull request from a fork gets no secrets, and a branch cannot use them. The API key for notarisation is a key of this repository's own, so it can be revoked alone.
- **Three parts.** `scripts/package.sh` makes `release/OpenSmartPen-<version>.dmg` and `.zip`. `scripts/verify-release.sh` refuses a build that Gatekeeper will not open. `.github/workflows/release.yml` runs both on a `v<version>` tag and puts the two files on a draft release.
- **A draft, not a release.** A person reads it and publishes it. A tag alone makes nothing public.
- **The tag must agree with `AppDelegate.version`.** The version has one home, and a tag that says something else is refused.
- **A release on a tag, not on each merge.** Brainio releases each merge to an internal channel. A public user must not get a build for each merge.
- **GitHub Releases, not a bucket.** The project is open and that page is where a person looks. It serves a download only when the repository is public.
- **The DMG is signed and notarised too,** not only the app in it. Gatekeeper judges the disk image first.
- **Without the Apple credentials the build is unsigned and says so.** It is not signed with the certificate of the Mac: a release is from the Developer ID or it is not a release.
- **The secrets have Brainio's names** (`MAC_CSC_LINK`, `MAC_CSC_KEY_PASSWORD`, `APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`), in a GitHub environment `release`. The team id is the variable `APPLE_TEAM_ID`.
- **Seen:** an unsigned build makes both files, the DMG holds the app, the Applications link and the license texts, and the verify script refuses it. **The signed path ran on 2026-11-17,** from the trial tag `v0.2.0-test1`: Apple accepted the app and the DMG, the verify script passed, and Gatekeeper on another Mac accepts the downloaded DMG as "Notarized Developer ID".
- **Not seen: the app under the hardened runtime.** A release is the first build that has it. Bluetooth and the photo from an iPhone must be tried on the first signed build.
- **The credentials are in the environment** (2026-11-17). The certificate came from the Brainio secrets; the API key is new and is named `opensmartpen` in App Store Connect.
- Open: updates. Planned: Sparkle in the app, with "Check for Updates…", and a Homebrew cask that points at the zip.
