---
title: Transcription reads the rendered image, and a page can carry commands
status: proposed
tags: [transcription, claude, commands]
summary: A page becomes text by rendering it and asking Claude to read the image, with the image kept beside the text as evidence; a line the writer opens with a command marker is transcribed as a task whose progress survives re-transcription.
---

# ADR-NNN: Transcription reads the rendered image, and a page can carry commands

**Date:** 2026-09-12
**Status:** Proposed
**Owner:** @matoushavlena

## Context

Handwriting has to become text, and two routes were open: stroke-based recognition, which has the
dots, and image-based, which has a rendered page. The user already photographs notes into Claude
Code with good results. Expected error on rushed handwriting is 6 to 12 per cent of characters,
and the characteristic failure is not a refusal but a fluent, confident, wrong reading.

## Decision

A page becomes text by rendering it and asking Claude to read the image, and **the image stays
beside the text** as the evidence that can be checked by eye. Where that reading happens is not
decided here: `DRAFT-a-page-is-read-by-an-agent` moved it from the local CLI to a DAM agent, and
this record keeps only what is asked of the reading itself.

- The image is rasterised from the strokes directly, never converted from the vector page. macOS
  Quick Look silently dropped strokes from a vector page and three different models then
  transcribed the broken image faithfully. A rendering fault and a recognition fault are
  indistinguishable once they are downstream.
- The image is cropped to the written area; the vector page keeps the true sheet. A line of writing
  marooned in an A4 of white space transcribes badly.
- The transcription carries frontmatter naming the page, the stroke count, when it was written, the
  model and the source image, and a standing instruction to check the image before relying on it.
- The model reproduces rather than improves: the original language, and the structure the writer
  used. It reads a hard word from its context where the context makes it plain, and marks one it
  genuinely cannot make out. The stricter earlier rule — never guess, never correct anything — was
  dropped on 2026-09-15: it filled the readings with bracketed notes about individual letters, which
  is a transcript of the model's doubts rather than of the page.
- **A line the writer opens with `>>` is an instruction addressed to an assistant**, transcribed as
  an unchecked task. Its progress is carried across re-transcription by matching the normalised
  text, because the Markdown is regenerated whenever raw changes while the paper cannot be
  un-written.
- A page is transcribed again only when its render is newer than its transcription.

## Alternatives Considered

- **Stroke-based recognition as the baseline** — on-device and incapable of hallucinating, but unproven here; it can run first and let Claude clean up if it wins a comparison.
- **An API key instead of the CLI** — one more secret to hold when the existing login already works. Taken in the end, in `DRAFT-a-page-is-read-by-an-agent`: a CLI on this Mac is not an agent, and the key is bound to one agent and kept in the Keychain.
- **Convert the vector page to an image** — this is exactly how strokes went missing.
- **Treat the transcription as the record** — ADR-001 puts truth in raw; the text is derived and disposable, which is what makes re-running it safe.
- **Keep command state in a separate file** — a second store to reconcile with a derived file that is rewritten on every render.

## Consequences

- **Easier:** any recognition choice can be revisited by deleting the derived files and running again, and nothing depends on a transcription being right the first time.
- **Easier:** an instruction written on paper has somewhere to record its progress without a second store — the transcription is the checklist.
- **Harder:** roughly one character in ten is wrong on rushed handwriting, and wrong fluently. Every consumer has to treat the text as a lead and the image as the record.
- **Harder:** carrying progress forward matches on text, so editing what a command says on paper, or writing the same instruction twice on one page, loses or confuses its state.
- **Committed-to:** the image beside the text, `>>` as the command marker, and the transcription as a derived file that may be regenerated at any time.
