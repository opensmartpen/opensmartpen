---
id: 001
title: Keep all captured data, and make the readable files from it
status: accepted
tags: [capture, format, source-of-truth]
summary: Every event is recorded as it occurs — a stroke, a setting or a command — and never changed. The readable files are made from that record, and can be made again at any time.
---

# ADR-001: Keep all captured data, and make the readable files from it

**Date:** 2026-09-10
**Status:** Accepted
**Owner:** @matoushavlena

## Context

The pen makes dots. Each dot has a position, a force, a time, a tilt and a twist. The pen makes approximately 120 dots each second. It sends the dots live, and also from its memory. It does not make pages, notes or images.

Not all that we must know is a mark on paper. A person selects an ink colour, or asks for work on a page. The pen has no command for ink colour, and it senses nothing when a person clicks in the app.

If we do not record an event at the time it occurs, the event is lost.

## Decision

We keep a record of all the events that occur. We write each event at the moment it occurs. We add events only to the end of the record, and we never change an event. This record is the source of truth.

There are three kinds of event:

- **Strokes.** These are the marks that the pen made. We keep the dots without changes. Each dot keeps its position in Ncode cells, its force, its time, its tilt and its twist. We do not change the values to millimetres or to pixels. We do not make the data smooth, and we do not remove dots.
- **Settings.** A setting changes how we draw or read the marks. An example is a new ink colour. To make a readable file, you must use the settings that were in force at that time.
- **Commands.** A command asks for work. An example is a request to share the rendered page. A command does not change how a page looks.

Replay makes the difference between the last two kinds. You use a setting again each time that you make a readable file. You do a command one time only. If you make the file again, you must not do the command again.

Each event records its client: the thing that produced it. Today there are two clients, the pen and the app. A new client writes its events to the same record, and nothing else changes.

A stroke needs a surface identity. That is the sheet or canvas the mark was made on. Only a client that senses a surface can give one. The pen senses Ncode paper, so every stroke it makes carries a page. The app senses no surface, so it makes no strokes. A person selects an ink colour, and no surface takes part.

Thus a setting or a command does not always have a page. We cannot keep it as part of one.

The pen does not know what a mark means. It reports the same dots for all that a person writes, and we always keep those dots as a stroke. Some parts of a page are active areas. When a person writes in an active area, we record a setting or a command as well. The stroke stays, and we still draw it.

We make all the readable files from this record. These are the SVG files, the PNG files, the text files, and the groups of pages that make a note. We can make them again at any time. A readable file is never the first place that holds a fact.

```
  the pen   writing                   ──► a stroke                    ─┐
            writing in an active area ──► also a setting or a command ─┤               ┌─► replay the settings ──► SVG, PNG, text
                                                                       ├─► the record ─┤
  the app   a click                   ──► a setting or a command      ─┘ (append-only) └─► do a command, one time only
```

To correct an error, add a new event. Do not change an event that is already in the record.

## Areas not covered

This decision tells you which events we record, and why the record is the source of truth. It does not tell you:

- Where we keep any of this, how the files are divided, and which names they have.
- How we divide the dots into strokes, or how we find a stroke that arrives two times.
- Which pen or notebook a setting applies to, and for how long.
- Where the active areas are, how we match dots to them, and how a new client is added.
- Where we get the page dimensions of a notebook.

## Alternatives Considered

- **Keep SVG files** — an SVG file loses the force and the time data. Also, to add one stroke, you must write the full file again.
- **Keep InkML files** — InkML is the correct standard. But the files are large, and no program that we use can read them. We can make InkML files later from the record.
- **Keep only the strokes, and calculate the settings later** — a stroke does not tell you the colour. The pen reports "no colour" for each live stroke. Also, a person can change a setting in the app, and that makes no stroke.
- **Make a setting part of a page** — a setting can occur when the pen is on no page at all. Then there is no page for it to be part of.
- **Write the colour and the width into each stroke** — then a correction to a setting makes you write the strokes again. We add only to the end to prevent this.

## Consequences

- **Easier:** you can change how we draw the pages, or how we read them, at any time. The record stays complete. A bad readable file is not a loss, because you can make it again.
- **Easier:** to record an event, we add one line. If capture stops, we lose only that line. A person can read the file without a special tool.
- **Harder:** you cannot draw a page from the strokes alone. You must know the page dimensions, because Ncode cells are not millimetres. You must also replay the settings before you can give a colour to a stroke.
- **Harder:** a program that makes a readable file again must not do the commands again. Each command needs a way to show that it is already done.
- **Harder:** there are three kinds of event, and more than one client. Thus a program that reads the record meets events with no page and no dots. The program must expect them.
- **Committed-to:** three things. We only add to the record and never change it. Each event carries its client. The values in a dot keep this sequence: `x, y, force, dt, tiltX, tiltY, twist`. If you change the sequence, you must increase the format version.
