---
title: Dots become strokes at capture, and duplicates are matched by content
status: proposed
tags: [capture, format, bluetooth]
summary: The dot stream is cut into strokes on the pen-up the SDK reports; a stroke carries absolute start and end plus per-dot deltas, and a stroke delivered twice across a reconnect is recognised by its dots rather than by an id.
---

# ADR-NNN: Dots become strokes at capture, and duplicates are matched by content

**Date:** 2026-09-12
**Status:** Proposed
**Owner:** @matoushavlena

## Context

The pen reports dots, not strokes — about 80 to 120 a second, each with force, tilt, twist and
the page it landed on — and it reports a pen-down and a pen-up around them. The same writing
reaches us by two paths, live over Bluetooth and drained from pen memory, and the two overlap: the
stroke in progress when a connection completes arrives twice, with about 23 ms of clock offset
between the copies (observed 2026-09-11). The pen gives a stroke no identifier of any kind.

## Decision

Dots are assembled into strokes at capture, on the pen-up the SDK reports, and the stroke is the
unit of the raw file: one line, carrying an absolute start and end in epoch milliseconds and a
millisecond delta per dot. A duplicate is recognised by content — same page, same dot count, same
first and last dot, start within half a second — because there is no id to match on.

The boundary is held defensively. A pen-down while a stroke is still open closes the open one
rather than discarding it; a dot that lands on a different page does the same; a disconnection
flushes what is in hand. Nothing is dropped for arriving in an unexpected order.

Which path a stroke came by is recorded and is the only thing that distinguishes the two: same
dots, same format, same file. The pen's clock is set on every connect so both paths share one
timebase.

## Alternatives Considered

- **Store the dot stream and segment later** — the hardware tells us where a stroke ends; recovering that downstream from timing and geometry is guessing at something we were told.
- **Match duplicates on timestamp** — the two copies differ by ~23 ms and unrelated strokes start near each other; the dots are the part that is actually identical.
- **Deduplicate downstream, in the renderer** — every consumer would need the rule, and raw would claim the pen made a stroke twice when it made it once.
- **Ask the pen for a stroke id** — NISDK3 exposes none.

## Consequences

- **Easier:** writing can be replayed exactly, because every dot carries its own delta (median 12 ms) and every stroke its own absolute start.
- **Easier:** reconnecting mid-sentence costs nothing. The rule fires on real data — logged 2026-09-11 as a dropped duplicate offline stroke on `s3/o1012/b3017/p5`.
- **Harder:** strokes buffered before a pen's first ever connect may carry an unsynchronised clock, so absolute times on a first drain are suspect while relative timing stays sound.
- **Harder:** lines are appended in arrival order, which is not chronological — offline strokes land after live ones — so every consumer must sort by start time before it does anything.
- **Committed-to:** the stroke as the atom of the format — the unit of a line, of deduplication and of timestamping — and the half-second duplicate window.
