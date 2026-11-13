---
name: adr
description: >
  Tracks Architecture Decision Records (ADRs) in docs/adrs/.
  Creates and updates ADRs following project conventions.
  TRIGGER when: user wants to record or update an architectural decision.
argument-hint: "[what you'd like to do]"
---

# ADR Tracking

Manage Architecture Decision Records in `docs/adrs/`. Interpret `$ARGUMENTS` as natural language.

ADRs are human-first: for ordinary work the agent-facing source of truth is the architecture docs, not the log. Reading `docs/adrs/` is allowed only for the job this skill does — authoring or updating an ADR. When you do, read `docs/adrs/index.md` first, then open only the records it points you to. Never read the log to understand the current system.

## What an ADR is, and what it isn't

An ADR is a **decision**, not a design document. It captures *what was decided* and *why*, so a future reader can recover the reasoning without rereading the surrounding code. It is not the place to explain how the decision is implemented.

A good ADR is short. Aim for under ~100 lines of body content. If a record is growing past one screen of prose, you're writing a design doc — the parts you'd cut to fit the shorter shape aren't worth keeping.

## Writing rules

- **Write the body in ASD-STE100** (simplified technical English). Short sentences, 20 words or fewer. One idea per sentence, active voice, one word for one thing. Replace jargon with plain words: *verbatim* → "without changes", *regenerable* → "we can make them again", *append-only* → "we add only to the end of a file". Avoid noun stacks: *page geometry* → "page dimensions". An ADR is read by somebody who has to act on it, not admired.
- **No project history.** `Context` states the constraint that forces the decision — what the hardware does, what a platform refuses, what a measurement showed. It never says "the first design was X" or "we originally planned Y". A reader needs the fact, not the path taken to it. A rejected earlier approach belongs in `Alternatives Considered`, named as an option, not as a past.
- **Lead with the thesis.** The first one or two sentences of `Decision` must state what was decided. A reader who stops there should already have the answer.
- **Name the decision, not the mechanism.** Don't name anything that could plausibly be renamed during implementation without changing the decision. Type names, function signatures, library version pins, env var names, struct fields, internal file paths — out. Interface-level names that the decision is *about* (a destination directory contract, a protocol identifier) are fine.
- **Consequences are non-optional, and balanced.** Every ADR ends with `Easier / Harder / Committed-to`. Both pros and cons must appear — a Consequences section with only upsides is a sales pitch, not a decision record. Drop labels that don't apply; add a fourth only when it captures something the three don't. This is the part future readers come back for.
- **Consequences must be objective.** Each bullet is backed by concrete evidence: a measurement, a prior incident, a constraint from a contract or platform, a count, a deadline. Subjective claims ("feels cleaner", "more elegant", "easier to reason about") don't belong — if you can't point at the evidence, the consequence isn't real enough to record.
- **One-line alternatives.** Each rejected option is `**Name** — reason`. If the reasoning needs a paragraph, the `Decision` section is under-stating something; fix that instead.
- **No code blocks except trivial inline, and at most one diagram.** Schemas, data samples and pseudo-code belong in design docs and the code, never in the ADR. One small ASCII diagram is allowed, and only when it shows a shape the prose cannot — how the parts relate, or where something flows. If the diagram needs a legend, or a second diagram, it is a design doc and does not belong here.
- **State what the record does not decide.** Every ADR carries an `## Areas not covered` section listing the subjects it forms no opinion on. Name the *subject* ("where we put the captured files, and which names they have"), never another record. Cross-links between ADRs go stale, because records get renamed, superseded and dropped; `docs/adrs/index.md` is the list that stays correct. A record that keeps acquiring claims outside its subject makes other records contradict it — ADR-001 took a path scheme, a per-page rule and a geometry source before this rule existed.
- **No re-statement.** If `Consequences` repeats what `Decision` already said, cut it. Each section earns its words.

## Drafting protocol

When creating or updating an ADR:

1. Draft the `Decision` thesis (one or two sentences) before anything else. Show it to the user. If it doesn't survive that read, the rest is wasted work.
2. Fill in `Context` only enough to motivate the thesis. Stop when the reader has enough.
3. Write `Consequences` before `Alternatives Considered`. Knowing the cost makes the alternative comparisons honest.
4. Read the whole thing top to bottom and cut. Remove any sentence that doesn't change the decision or its cost. If two sentences say the same thing, keep the shorter one.

## Frontmatter (required)

Every ADR starts with a YAML frontmatter block. The index is *generated* from it, so the fields must be present and honest:

```yaml
---
id: NNN                    # zero-padded, matches the filename; omit for DRAFT-
title: Title
status: accepted           # accepted | proposed | deprecated
supersedes: NNN            # id this record replaces (optional)
tags: [envoy, secrets]     # optional free list
summary: One line stating what was decided.
---
```

- `supersedes` is a forward link only. The superseded record's status is *derived* by the generator — never hand-stamp the old file.
- `summary` is the one-liner the index shows; write it so a reader can decide whether to open the full record.

## The running log is not the ADR log

`docs/decisions.md` and `docs/adrs/` split by genre. The log keeps measurements, incidents, dead ends, open questions and ideas — things that are not decisions. An ADR keeps one decision.

When an accepted ADR takes a decision, **delete that entry from the log.** Do not leave a pointer behind: the same argument in two places is free to drift apart. Cut whole sections when they graduate whole, single bullets otherwise, and keep anything no ADR records even inside a graduated section.

A proposed `DRAFT-` record does not count. Its material stays in the log until the record is accepted.

## Creating an ADR

Ask the user for any missing information. You need at minimum: title, context, decision, owner (@github-username), and the frontmatter fields above.

If the decision is made → create `docs/adrs/NNN-short-title.md` with status `accepted`.
If the decision is open → create `docs/adrs/DRAFT-short-title.md` with status `proposed` (omit `id`).

Read `docs/adrs/index.md` for the next free number. After creating the file, add its row to `docs/adrs/index.md` (hand-maintained in this repo).

## Updating an ADR

Valid status transitions: `accepted`, `deprecated`, and supersession via the *new* ADR's `supersedes` field (never edit the superseded file's body — its status is derived).

Read the target ADR directly. An accepted body is immutable: only its status changes, and only to superseded via the *new* ADR's `supersedes` field. There is no commit hook here, so hold that rule yourself.

When promoting a Draft to Accepted: rename `DRAFT-title.md` → `NNN-title.md` with `git mv`, set `id` and `status: accepted` in the frontmatter, then move its row in `docs/adrs/index.md` from Proposed to Accepted.

## Conventions

- **Accepted**: `NNN-short-title.md` — numbered, zero-padded to 3 digits, never reused
- **Drafts**: `DRAFT-short-title.md` — no number until accepted
- **Owner**: the person accountable for the decision — drives it to resolution, revisits if context changes
- File names: short kebab-case, 2-3 words max
- Index: `docs/adrs/index.md` — hand-maintained; keep it in sync with frontmatter

## Template

See [`docs/adrs/template.md`](../../../docs/adrs/template.md) for the section skeleton.
