---
id: 001
title: Raw stroke log per page is the source of truth
status: accepted
subsystem: stroke-format
tags: [storage, format]
summary: Every page is an append-only JSON Lines file of raw pen dots in Ncode cells; SVG, PNG and text are derived and regenerable.
---

# ADR-001: Raw stroke log per page is the source of truth

**Date:** 2026-09-10
**Status:** Accepted
**Owner:** @matoushavlena

## Context

The first design named "one SVG per note" as the stored artefact. The pen does not produce SVG or notes; it produces dots with pressure, timing, tilt and a page identity, at about 120 per second, both live and from its offline memory. Anything we do not keep at capture time is gone.

## Decision

The stored unit is one append-only JSON Lines file per physical page, keyed by the Ncode identity (section, owner, book, page), holding strokes of raw dots exactly as the SDK reports them: coordinates in Ncode cells, force 0…1, per-dot time deltas, tilt and twist. SVG, PNG, transcriptions and any grouping into notes are derived from these files and may be regenerated at any time. Raw files are never edited or rewritten, only appended to.

## Alternatives Considered

- **SVG as the stored format** — loses pressure and timing unless smuggled into attributes, and appending a stroke means rewriting the file.
- **InkML** — the right standard but XML-verbose and unneeded by any consumer we have; can be emitted from the raw log later.
- **One file per note** — a note is a human grouping the pen knows nothing about; it would have to be guessed at capture time and could not be changed afterwards.

## Consequences

- **Easier:** any rendering or recognition choice can be revisited without touching capture; a stroke append is one line and a page's history is a plain `git log`.
- **Harder:** every consumer needs page geometry (from `.nproj` or measurement) before it can draw anything, because cells are not millimetres.
- **Committed-to:** the field order inside a dot array (`x, y, force, dt, tiltX, tiltY, twist`) and the path scheme `raw/s{section}/o{owner}/b{book}/p{page}.jsonl`; changing either is a format version bump.
