---
id: 005
title: A macOS menubar app owns the pen
status: accepted
tags: [topology, macos, capture]
summary: Capture is a thin, unattended macOS menubar app that is the only thing that talks to the pen; it writes raw pages and an image of each page, and does no recognition or transcription.
---

# ADR-005: A macOS menubar app owns the pen

**Date:** 2026-09-10
**Status:** Accepted
**Owner:** @matoushavlena

## Context

The first plan was an iOS app streaming strokes in real time to an agent that would render and transcribe on every change. Research then showed the A1 pen buffers 160 pages of offline memory and NeoLAB's SDK 3.0 builds for macOS, which removes the reason to stream: the pen itself is the buffer, and a laptop can drain it whenever the two are in the same room. The user wants notes digitised within about ten minutes of writing and wants to never think about the sync.

An agent that transcribes a page looks at an image. To draw that image, an agent needs the strokes, the ink in force at each stroke, and the colours.

## Decision

One macOS menubar app owns the pen, and nothing else talks to it. It connects whenever the pen is in range, drains the pen's offline memory, receives live strokes and writes raw pages. It also draws an image of each finished page and keeps it beside the raw page.

It does no recognition and no transcription; those run elsewhere, off the files the app writes. It runs unattended — no launch, no button, no daily gesture — and it addresses the person only when something is wrong, through macOS notifications.

Exactly one agent owns a pen at a time. Two would both hold the Bluetooth connection and both write the same pages.

Where the files go after they are written is **not** decided here. This record ends at the files on disk: the raw page and its image.

## Alternatives Considered

- **iOS app with real-time streaming** — background Bluetooth and networking limits, App Store or TestFlight friction with a GPL SDK, and real time is not a requirement.
- **Recognition inside the same app** — puts model calls on a laptop that may be asleep, and couples capture releases to recognition changes.
- **Each agent draws the page** — each agent then needs the ink rules and the colours, and two drawings can disagree with nothing to show it.
- **A background daemon with no menubar presence** — the pen needs pairing, authorisation and occasional attention after a failure, and a thing with no window cannot ask for any of it.

## Consequences

- **Easier:** capture is testable without hardware, because everything below the SDK boundary is ordinary unit-tested code; and the processing side can be rewritten freely, because its input is files rather than a running program.
- **Easier:** an agent needs no drawing code. The image is ready beside the strokes.
- **Harder:** a drawing fault in the app reaches every agent. On 2026-09-14 the app drew a page upside down, and only the agent found it.
- **Harder:** latency is bounded below by the Mac being awake and the pen being in range. A page written away from the Mac waits until the two meet, and the 160-page pen memory is what covers the gap.
- **Committed-to:** one owner per pen, and the files on disk as the point where this app's responsibility ends.
