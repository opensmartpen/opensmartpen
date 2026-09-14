---
id: 005
title: A macOS menubar app owns the pen
status: accepted
tags: [topology, macos, capture]
summary: Capture is a thin, unattended macOS menubar app that is the only thing that talks to the pen; it writes raw pages and does no rendering, recognition or transcription.
---

# ADR-005: A macOS menubar app owns the pen

**Date:** 2026-09-10
**Status:** Accepted
**Owner:** @matoushavlena

## Context

The first plan was an iOS app streaming strokes in real time to an agent that would render and transcribe on every change. Research then showed the A1 pen buffers 160 pages of offline memory and NeoLAB's SDK 3.0 builds for macOS, which removes the reason to stream: the pen itself is the buffer, and a laptop can drain it whenever the two are in the same room. The user wants notes digitised within about ten minutes of writing and wants to never think about the sync.

## Decision

One macOS menubar app owns the pen, and nothing else talks to it. It connects whenever the pen is in range, drains the pen's offline memory, receives live strokes and writes raw pages.

It does no rendering, no recognition and no transcription; those run elsewhere, off the raw files. It runs unattended — no launch, no button, no daily gesture — and it addresses the person only when something is wrong, through macOS notifications.

Exactly one agent owns a pen at a time. Two would both hold the Bluetooth connection and both write the same pages.

Where the raw pages go after they are written is **not** decided here. This record ends at the raw file.

## Alternatives Considered

- **iOS app with real-time streaming** — background Bluetooth and networking limits, App Store or TestFlight friction with a GPL SDK, and real time is not a requirement.
- **Processing inside the same app** — puts model calls and rendering on a laptop that may be asleep, and couples capture releases to recognition changes.
- **A background daemon with no menubar presence** — the pen needs pairing, authorisation and occasional attention after a failure, and a thing with no window cannot ask for any of it.

## Consequences

- **Easier:** capture is testable without hardware, because everything below the SDK boundary is ordinary unit-tested code; and the processing side can be rewritten freely, because its input is files rather than a running program.
- **Harder:** latency is bounded below by the Mac being awake and the pen being in range. A page written away from the Mac waits until the two meet, and the 160-page pen memory is what covers the gap.
- **Committed-to:** one owner per pen, and the raw file as the point where this app's responsibility ends.
