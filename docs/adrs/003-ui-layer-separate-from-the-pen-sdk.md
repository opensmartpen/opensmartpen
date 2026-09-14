---
id: 003
title: The UI is a layer of its own, and design fixtures ship in nothing
status: accepted
tags: [macos, layering, design]
summary: The macOS app splits into BrainioPenCore, BrainioPenUI (every view, no pen SDK, reaching the pen only through a PenLink protocol) and the app itself; the design window and its fixtures live in a separate executable that nothing else can import.
---

# ADR-003: The UI is a layer of its own, and design fixtures ship in nothing

**Date:** 2026-09-12
**Status:** Accepted
**Owner:** @matoushavlena

## Context

The panel is worked on by looking at it. A design window already existed for that: it drew the
panel in both appearances with a picker for ten states, and `dev-design.sh` rebuilt and reopened it
on every save. Several of those states — a failing push, a pen memory drain, a first run — take
deliberate setup to provoke with real hardware, so fixtures are the only practical way to see them.

All of it lived in the shipped app. `DesignWindow.swift` compiled into the release binary behind an
environment variable, and the ten states sat inside `PanelModel.swift`, the production model: 130
lines of make-believe among the code that derives the real thing. They were there for a mechanical
reason — `private(set)` on the published properties is scope-limited, so only code in that file
could set them.

The layering underneath had the same shape. `BrainioPenCore` was clean, but every view, the model
and the pen SDK were one target. `PanelModel` held a `PenSession`, and `PenSession` imports
NISDK3, so nothing about the panel could be built, run or tested without the vendor SDK.

## Decision

Four targets, each unable to reach the one above it:

- **`BrainioPenCore`** — the domain. Foundation only. Unchanged.
- **`BrainioPenUI`** — every window and view, and the model. Knows the domain; knows nothing of the
  pen SDK. It reaches the pen through `PenLink`, a protocol of plain values (`PenLinkState`,
  `DrainProgress`, `PenReport`), so the SDK's own types stop at the app layer.
- **`BrainioPen`** — the app. `PenSession` is the only conformance to `PenLink`. It links NISDK3.
- **`BrainioPenDesign`** (+ a thin `BrainioPenDesignApp`) — the design window and the fixtures,
  built as `brainio-pen-design`, a separate app. Nothing else imports it.

The model gives the design window one seam and no fixtures: `PanelModel.Snapshot`, every published
property as a single value, and `apply(_:)`, which shows exactly what it is handed and derives
nothing. The scenarios that build those snapshots live in `BrainioPenDesign`.

`BRAINIO_PEN_DESIGN=1` is gone. Design mode is an app, not a flag.

## Alternatives Considered

- **Leave it as it is.** The design code is small and the environment variable does gate it. But
  fixtures in the production model are read as fact by the next person, and a UI that cannot be
  built without the pen SDK cannot be snapshot-tested or exercised on a machine with no pen.
- **Move only the fixtures out, keep one target.** This was done first and is most of the value for
  a fraction of the work. It does not stop the design window shipping, and it does not let anything
  build the UI without NISDK3.
- **`@testable import` from the design executable.** Would have avoided making the UI surface
  public. It works only in debug builds, and buying a smaller diff with a build-configuration trap
  is a poor trade.
- **Fixtures in the executable rather than in a library.** One target fewer. A test target cannot
  depend on an executable, so the states would have to be written twice the day the panel gets
  snapshot tests.

## Consequences

- The shipped binary contains no fixture and no design window. This is checkable: the fixture
  strings do not appear in `strings .build/release/brainio-pen`.
- The UI layer builds and runs with no pen, no Bluetooth and no SDK. Snapshot tests over
  `Scenario` are now possible; none are written yet.
- What the UI layer exposes to the app is now a deliberate, public surface rather than everything
  by default. Adding a window means deciding what the app may call on it.
- The SDK's `PenSettingStruct` no longer reaches the panel. A new reading from the pen has to be
  named in `PenReport` before the panel can show it — a small tax, paid to keep the wall.
- The viewer still has no design window. It is the largest UI file and the one part still worked
  on by running the whole app. Giving it one is now a matter of adding a window, not of moving
  layers.
