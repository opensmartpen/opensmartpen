---
id: 004
title: A page moves only when it is finished, and a buffer empties only on confirmation
status: accepted
tags: [capture, durability, quiet-window]
summary: A page is handed on only after the pen has been quiet for a set window, a notebook is deleted from pen memory only after that hand-off confirms, and what is still outstanding is found from the stored files, not from a list of pending pages.
---

# ADR-004: A page moves only when it is finished, and a buffer empties only on confirmation

**Date:** 2026-09-12
**Status:** Accepted
**Owner:** @matoushavlena

## Context

Three places hold a stroke between the paper and its destination: the pen's own memory (160 A4 pages), the raw file on disk, and whatever the raw file is published into. Every hand-off can fail — a transfer can stall, a publish can be refused, the Mac can be shut down mid-page. On 2026-09-11 a restart stranded a page that had been written but not yet published, because the list of pages waiting lived only in memory.

There is also no signal that says a page is finished. Paper has no save button, and the pen reports a pen-up after every word. A person also goes back to an earlier page in the same sitting, so a page that is left is not a page that is finished.

## Decision

Nothing is released early. A page is handed on only once it is finished, and a buffer is emptied only once the next one has confirmed what it held.

- **A page is finished when the pen has been quiet.** Pages are handed on once no pen has reported an event for a set window. The wait is on the pen, not on each page. All pages of one sitting go together, one time.
- **Strokes drained from pen memory are finished on arrival.** They were written before the connection existed, so they wait for nothing.
- **A drained notebook is deleted from pen memory only after the publish of its pages confirms.** A failed publish keeps the strokes on the pen and says so in the log.
- **A notebook is the unit of the drain**, because it is the unit the pen's own memory and delete commands work in.
- **What is outstanding is found from the stored files.** The app keeps no list of pending pages. A page image that is older than its strokes is outstanding. For a remote destination the app keeps a list of what it sent, with the size and date of each file, and a file that differs is outstanding.
- **A failed publish is retried with backoff** and reported only after three attempts, and the report says how many pages are safe on disk before it says anything about the destination.

## Alternatives Considered

- **Publish every stroke as it arrives** — a half-written page reaches processing, and a transcription of half a sentence is worse than none.
- **Publish on pen-up** — the pen reports pen-up between words, so a page would be published dozens of times while it is still being written.
- **Let the person say when a page is done** — the whole point is that nobody thinks about the sync.
- **Delete from the pen as each notebook finishes transferring** — the drain is the least durable moment; a crash between transfer and publish loses pages the pen no longer holds.
- **Keep the pending list in a state file** — a second record of something the stored files already know, free to disagree with them; it was the memory-only version of exactly this that stranded a page on 2026-09-11. A list of what was sent is different: if it is lost, each file is sent again and no page is lost.
- **Time each page on its own** — a page left for another page is sent before it is finished, and a reader gets one sitting in parts.
- **Never delete from the pen** — the 160 pages then fill, after which the pen stops keeping offline strokes at all.

## Consequences

- **Easier:** a pen carried away from the Mac is a 160-page buffer rather than a risk, and strokes survive a crash, a refused publish and a restart. The restart path is covered by tests.
- **Easier:** every published page is a finished page, so anything downstream can treat what it receives as complete and never has to detect a half-written one.
- **Harder:** the quiet window is a floor on latency that no amount of speed elsewhere can remove, and a page picked up again after the window has passed is published a second time.
- **Harder:** a pen that continues to write holds back each finished page of that sitting.
- **Harder:** a deletion the pen never confirms has to be timed out rather than waited on, so that notebook stays on the pen and is drained again at the next connection.
- **Committed-to:** the stored files as the record of what is outstanding, one agent per pen, and a quiet pen as the only definition of finished.

## Areas not covered

- Where a finished page is handed on to.
- How long the quiet window is.
- What a reader does with a page it receives.
