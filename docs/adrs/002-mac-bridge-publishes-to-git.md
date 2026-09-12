---
id: 002
title: A macOS bridge publishes raw pages to git; processing happens elsewhere
status: accepted
subsystem: architecture
tags: [topology, macos, git]
summary: Capture is a thin, autonomous macOS menubar app that commits quiet pages to a GitHub repo; rendering and transcription run in a DAM agent off that repo.
---

# ADR-002: A macOS bridge publishes raw pages to git; processing happens elsewhere

**Date:** 2026-09-10
**Status:** Accepted
**Owner:** @matoushavlena

## Context

The first plan was an iOS app streaming strokes in real time to a DAM agent that would render and transcribe on every file change. Research showed the A1 pen buffers 160 pages offline, NeoLAB's SDK 3.0 builds for macOS, and DAM has no file-change trigger and cannot receive uploads while hibernated. The user wants notes digitised within about ten minutes of writing and wants to never think about the sync.

## Decision

Capture and processing are split by a git repository. A macOS menubar app (Brainio Pen, called PenBridge when this record was written) owns the pen: it connects whenever the pen is in range, drains offline memory, receives live strokes, and commits each page to the repo once it has been quiet for ten minutes, pushing to GitHub. It deletes a notebook from the pen only after that notebook's commit is pushed. It has no rendering, recognition or DAM knowledge. It runs unattended and reports only problems, through macOS notifications. A DAM agent, always on, watches the repo and produces every derived artefact.

## Alternatives Considered

- **iOS app with real-time streaming** — background Bluetooth and networking limits, App Store or TestFlight friction with a GPL SDK, and real time is not a requirement.
- **Bridge uploads straight into DAM** — DAM's upload route fails on a hibernated agent and offers no trigger; git gives durability, history and a trigger surface for free.
- **Processing inside the bridge** — puts model calls and rendering on a laptop that may be asleep, and couples capture releases to recognition changes.

## Consequences

- **Easier:** the bridge is testable without hardware (all logic below the SDK boundary is unit-tested against real `git`), and the processing side can be rewritten freely because its input is files in a repo.
- **Harder:** latency is bounded below by the quiet window plus the Mac being awake and in range; a page written away from the Mac waits until the pen and Mac meet. Pen memory (160 pages) is the buffer.
- **Committed-to:** the notes repository as the contract between the two halves, and "only quiet pages are committed" as the rule that keeps half-written pages out of processing.
