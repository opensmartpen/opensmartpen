---
id: NNN                       # zero-padded, matches the filename; omit for DRAFT-
title: Title
status: accepted              # accepted | proposed | deprecated
supersedes:                   # id this record replaces (optional); superseded status is derived from it
tags: []                      # optional free list
summary: One line stating what was decided.
---

# ADR-NNN: Title

**Date:** YYYY-MM-DD
**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-NNN
**Owner:** @github-username

## Context

What changed, or what gap surfaced, that forces a decision now. One short paragraph. Stop when the reader has enough to understand *why now*.

## Decision

Open with one or two sentences naming what was decided. A reader who stops here should already have the answer. The rest of the section names the rules and boundaries of the decision — not the mechanism that implements it.

## Areas not covered

The subjects this record forms no opinion on. Name the subject, never another ADR — cross-links go stale when records are renamed, superseded or dropped. `docs/adrs/index.md` is the list that stays correct.

- Subject this record does not decide.
- Subject this record does not decide.

## Alternatives Considered

- **Name** — why rejected, one line.
- **Name** — why rejected, one line.

## Consequences

Pros and cons, both stated, each backed by concrete evidence — a measurement, a prior incident, a constraint, a contract. No "feels cleaner," no "more elegant."

- **Easier:** what now becomes cheap, possible, or obvious — and the evidence that it does.
- **Harder:** what now costs more, or what future work has to work around — and the evidence that it does.
- **Committed-to:** what's now load-bearing — the thing a future reader would ask "do we still need this?" about.
