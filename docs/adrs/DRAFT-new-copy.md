---
title: When in doubt, a new copy
status: proposed
tags: [capture, heuristic, ncode]
summary: Two signals decide whether a notebook is a new copy — a sequence restart and ink overlap — and neither may decide without a silence before it; when the signals disagree we choose the new copy, because a wrong split is visible and repairable while a wrong merge is neither.
---

# ADR-NNN: When in doubt, a new copy

**Date:** 2026-09-14
**Status:** Proposed
**Owner:** @matoushavlena

## Context

Two pads of the same product carry the same surface identity. The app must put each stroke into one copy at the moment it arrives, and it never asks a person.

At that moment a new pad and a return to an old page look the same. Both are fresh ink on a page that already has writing, after a long gap.

The two mistakes do not cost the same.

A wrong split puts today's note in a second folder. You see a second book, so you find out at once. The repair is to move pages, which changes no file.

A wrong merge puts two pads into one page file. The strokes interleave inside that file. Nothing looks wrong until a page is drawn with two notebooks on one sheet. The repair needs the file to be cut in two, and we do not cut captured files.

## Decision

When the signals disagree, we choose the new copy. A wrong split is visible and cheap. A wrong merge is silent and expensive.

Three signals, and they do not carry equal weight.

- **Ink overlap.** A page's worth of new writing lands on the ink already on the sheet. One sheet cannot hold the same writing twice.
- **A sequence restart.** Ink appears on the lowest written page and then moves forward, page after page. Coming back to annotate does not march forward.
- **A long silence.** Weeks between the last stroke and the new one. This never decides anything by itself, because a notebook is allowed to rest.

Silence raises the question. One of the other two answers it. **Neither of them may answer a question that was not raised.** A signal with no silence in front of it is not evidence.

That rule is what makes ink overlap mean anything. Writing is strokes landing on other strokes. The letters of one word sit closer together than the width of a stroke. Thus every mark a person makes lands on the mark before it. Overlap separates two notebooks only when the ink below is *old*.

So overlap needs three things at once, and the first two are what make the third readable:

- **The page was put down and picked up again.** Hours, not minutes. A sitting is not evidence.
- **A page's worth of writing arrived, not a mark.** One stroke is never a notebook, however exactly it lands on an old one.
- **Half the arriving ink lands on old ink**, not a quarter.

We measure the silence from the newest stroke in the page's own file. We never measure it from something the app remembers. A notebook comes back from pen memory long after newer writing. Thus a remembered "last stroke" is out of order at the moment it matters most.

**A new copy is announced by existing.** A second book appears in the panel, which is how a person learns it happened. The app posts no notice, because a new notebook is not a fault.

**Every copy decision is recorded.** `book.json` holds when the copy began and which signal decided it. A person who disagrees can then see what the app saw.

## Areas not covered

- How long a silence must be before it raises the question.
- How much overlap counts as overlap.
- What tool moves pages between books, and who starts it.
- What happens to a book with no writing in it, made by a wrong split.

## Alternatives Considered

- **Ask the person** — the app must run without attention. A question at the wrong moment is worse than a guess we can repair.
- **Decide on silence alone** — a notebook can rest for months, so every holiday would make a new copy.
- **Prefer the copy already in use when unsure** — this chooses the mistake that cannot be undone without cutting a captured file.
- **Never decide, and keep one copy always** — two pads then write into the same pages, and every rendered sheet holds two notebooks.
- **Decide later, when there is more evidence** — a page must be filed when it arrives, and waiting leaves strokes with no home.
- **Let ink overlap decide on its own** — tried, and it made one A4 pad into five copies in a day, then two hundred copies from two hundred strokes. Asked of each stroke as it arrives, "does this land on ink already here" is a description of handwriting.

## Consequences

- **Easier:** we design against the expensive mistake. The worst outcome is then an extra book that a person can merge.
- **Easier:** the decision is written down with its reason, so a person can check the app rather than guess at it.
- **Harder:** revisiting an old notebook after months, and writing forward from where you stopped, looks exactly like a new pad. That case will split wrongly.
- **Harder:** a second pad opened the same afternoon the first was put down has no silence in front of it, so nothing decides and the two merge. That is the expensive mistake, and we take it on purpose. The other rule fires on ordinary writing, which is wrong every day instead of rarely.
- **Harder:** a repair needs a tool that moves pages between books. Until it exists, a wrong split is fixed by hand.
- **Committed-to:** the new copy as the answer when signals disagree, a silence in front of every signal, and the reason for each copy decision being kept in `book.json`.
