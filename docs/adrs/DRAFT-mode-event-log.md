---
title: Ink and width are our state, kept as an event log
status: proposed
tags: [capture, rendering, control-surface]
summary: The pen cannot be told an ink colour, so colour and line width are state on the Mac, recorded as an append-only log of changes stamped with each tap's own time; a return to defaults is derived from the gap between strokes and never written.
---

# ADR-NNN: Ink and width are our state, kept as an event log

**Date:** 2026-09-12
**Status:** Proposed
**Owner:** @matoushavlena

## Context

The LAMY notebook ships with a printed colour strip, which is itself Ncode paper with its own book
code. Tapping it changes nothing in the data: every stroke came back black however many swatches
were tapped, and NISDK3 has no ink command at all — only one that sets the pen's LED. So the
choice exists only if we keep it. A tap made away from the Mac sits in pen memory and is delivered
at the next drain, hours later, after events that happened long afterwards.

## Decision

Ink colour and line width are our state on the Mac, recorded in the notes repository as an
append-only log of changes, one line per change, stamped with the tap's own time on the same clock
as a stroke's start.

- **Only the field that changed is written.** A line carrying full state would describe the state
  at the moment it was written, not at the moment of the tap.
- **Readers replay in timestamp order, not file order**, because a drain appends out of order.
- **Returning to the pen's defaults is derived, never written.** It follows from the gap between
  consecutive strokes across the whole repository, and the defaults are the pen's own, from its
  record. No third writer exists, so nothing can fall out of step.
- **Only deliberate human acts are events:** a tap on the strip, a click in the panel. The pen's
  own power-off is logged as evidence and never joined on — we hear it only while connected, so a
  derived file depending on it would not be reproducible.
- **Ink names and their values live in the repository, not in code,** so the panel and the renderer
  cannot disagree about a colour. A swatch with no value assigned is stored as evidence and selects
  nothing.
- **The strip is a control surface.** Its taps are stored in raw, because the pen saw them, but
  they never enter the publish queue and never produce a rendered page. This is the first place
  where derived is a deliberate subset of raw rather than a regeneration of it.

## Alternatives Considered

- **Tell the pen which colour to stamp** — impossible; the SDK offers only the LED.
- **Keep a current ink value instead of a log** — a whole morning's pages would render in the colour selected that evening.
- **Write full state on every event** — a line written at 18:05 cannot know about a tap made at 09:20 that has not drained yet, and would claim a width that was never in force.
- **Write a reset event on a timer** — a fourth thing to keep in step, when the gap between strokes already carries the answer.
- **Use the strip's published button map** — the file describes a different product; the tap that "landed in no rectangle" turned out to be the red swatch. The map is built from measured taps instead, matched to the nearest column and then the nearest row, refusing a tap far from every button.

## Consequences

- **Easier:** a page renders in the ink chosen when it was written, whenever it happens to drain.
- **Easier:** the LED can acknowledge a choice at the moment of tapping, which is the only acknowledgement paper can give back.
- **Harder:** a mode is invisible on paper once set, so a wrong selection is silent and permanent, and the LED cannot indicate it either — the pen sleeps after five minutes and the LED dies with it. Three pens in three roles would remove this problem rather than solve it.
- **Harder:** how long a silence must be before defaults return is still undecided. Both observed resets followed a power cycle, so no timer is yet justified by evidence.
- **Open: a name is defined outside the record, so its meaning can change under old pages.** An event stores the name `yellow`, and the colour comes from the palette when we draw. Change the palette, draw again, and every old yellow page becomes the new colour. This is correct when we correct a measurement — five of the ten inks are estimates today — and wrong when we change our mind, because it repaints last month without telling anybody. The mechanism cannot tell the two apart.

  Two ways to answer it:

  - **Store the value, not the name.** The event holds the colour and the width themselves. The record is then complete on its own, and a page always draws as it did. But a bad estimate becomes permanent, and no correction can reach an old page.
  - **Store the name and give the palette a version.** An old page keeps the palette that was in force when it was written. When the app changes, each version is migrated or frozen on purpose. The owner's leaning, because it keeps the correction and the change of mind apart.

- **Committed-to:** the mode log as append-only and never rewritten, the tap's own time as its stamp, and the palette in the repository as the single source of colour.
