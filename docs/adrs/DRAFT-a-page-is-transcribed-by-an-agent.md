---
id:
title: A page is sent to an agent to be transcribed
status: proposed
tags: [transcription, dam, post-processing]
summary: A page that has been still for a minute is drawn as a PNG by the app, put in a DAM agent's workspace beside the transcript it already has, and transcribed in one prompted turn; the Markdown that comes back is written next to the strokes, what is still owed is read from the files rather than remembered, and a line addressed to an assistant is only ever carried out by a separate turn that somebody asked for.
---

# ADR-XXX: A page is sent to an agent to be transcribed

**Date:** 2026-09-14
**Status:** Proposed
**Owner:** @matoushavlena

## Context

Two records said how a page becomes text, and neither could work as written.

`DRAFT-image-transcription` gave the transcription to the local `claude` CLI. That keeps the transcription on this Mac, where the notes are, but it cannot use the tools, the skills or the memory of an agent. `docs/processing.md` gave the transcription to a DAM agent that polls `~/Brainio/pen` every few minutes. A DAM agent runs in a pod. It cannot see this disk.

There is also no trigger in DAM for a changed file. Something on this Mac must decide when a page is finished and must say so.

The wait matters. A commit is a record and can wait ten minutes. A transcript is what a person looks for when they put the pen down.

## Decision

When a page has been still for a minute, the app draws it, sends it, asks for a transcript, and files the answer.

- **The app draws the PNG.** The agent is given a picture, not strokes. It then needs to know nothing about Ncode cells, paper sizes, pressure or the ink in force.
- **The image goes to the agent's workspace**, at `pen/<copy>/p<n>.png`, through the api-server route that waits for the agent to be ready. The upload wakes a sleeping agent, so nothing else has to start it.
- **The transcript we already have goes up with it**, at `pen/<copy>/p<n>.md`. The paper is the same sheet as before with more writing on it, so the agent corrects its own earlier transcript. This is how a task already ticked off stays ticked.
- **One prompt, one turn.** The app opens the agent's ACP relay, makes a session, sends one prompt and waits for the turn to end — what `dam run` does.
- **The answer is written beside the strokes**, at `books/<copy>/pages/p<n>.md`, under the same name as the captured file (ADR-002). It is derived: it is never edited by hand and it can be made again (ADR-001).
- **What is owed is read from the files.** A page needs transcribing when its captured file is newer than its transcript. There is no list of pending pages and no state file, so a restart needs no recovery (ADR-004).
- **The prompt is written by the app**, not held on the agent, because the paths in it and the marker for a command are decided on this side.
- **A line addressed to an assistant is never carried out by a transcription.** The transcript only lists it, in `books/<copy>/pages/p<n>.actions.json`. Carrying one out is a separate turn, asked for by a click, naming one line and saying to leave the rest alone — with the page and everything said about that line sent along.
- **That turn writes nothing. Its reply is the deliverable**, kept in the action's `thread`, and the one thing read out of it is a status line the prompt asks for. `STATUS: done` ticks the box; anything else, a missing status included, leaves it open. A model that says it has finished has not said so in the one place the app reads.
- **The agent that transcribes is not the agent that acts.** The page goes to a transcriber chosen for having no confidential connections, because it is looking at an untrusted document; the agents with Slack, mail and the rest are only ever reached by a line a person has seen routed to them. The others are assistants, and each is switched on by a person: switching one on asks it what it is for and what it can reach, and until it has answered no line is offered to it. The transcriber is shown the assistants that have answered so it can *propose* one per line — a field in a file, never a hand-over. An unrouted line goes to the transcriber, which can do nothing with it.
- **Turns after the first carry on in the same DAM session**, with `session/load` — what `dam run --session` sends. The app's own thread goes in the prompt as well, because a pod that restarted has forgotten the session and the file has not.
- **That file is the one thing here that is not derived.** `done`, `dismissed` and the thread are facts about the world and about the writer's decisions, so a later transcription can set the flags but never clear them, and knows nothing of the thread. Only a person clears them, with an undo on the row.
- **The key is in a file of its own**, `dam-key` beside `config.json`, readable only by its owner. Not in the config, because a config is pasted into bug reports; not in the Keychain, because the Keychain's protection is tied to a code signature this app does not have a stable one of — see the decision log for 2026-09-15. With any of host, transcriber or key missing, transcription is off and everything else works as before.

- **A line being carried out can be stopped by DAM, and then the question comes to the person.** Both kinds arrive on the same socket and are answered in two different places: an egress hold belongs to the platform's gate and is answered in the approvals queue; a tool call is the agent's own and is answered on the socket. The card sits on the line that caused it, the turn keeps waiting, and the deadline stops running while somebody decides.

Two things a **transcription** deliberately does not do, because nobody is watching it:

- **A permission request ends the run.** It is mirrored into DAM's approvals queue, where a person deals with it. Waiting instead would hold a turn open for an hour and say nothing. A line being carried out is different: a person clicked it, so there is somebody to ask.
- **A dropped socket ends the run.** The turn carries on at the agent. The page is transcribed again at the next tick, because its captured file is still the newer of the two.

## Alternatives Considered

- **A schedule on the agent that polls its own workspace** (how `read-later` does it) — it still needs the app to upload, it adds a second place to configure, and it adds up to a minute of waiting for nothing.
- **Upload the captured strokes and let `pipeline/render.py` draw** — one renderer instead of two, but the agent would then need the paper size, the palette and the mode log: the whole drawing rule, to make a picture the app can already make.
- **The local `claude` CLI** (`DRAFT-image-transcription`) — no key to hold, but the transcription happens with no agent behind it, and only while this Mac is awake.
- **Shell out to the `dam` CLI** — the least code, but it puts a Node CLI on the critical path of a menubar app.
- **Keep a list of pages that have been sent** — a second record of something the files already say, free to disagree with them. ADR-004 rejected exactly this.
- **Send every page as it is written** — a half-written page reads badly, and the agent would be asked to transcribe the same sheet dozens of times.

## Consequences

- **Easier:** a page becomes text about a minute after the pen goes down, with no schedule, no cron and nothing to start.
- **Easier:** transcribing again is free and safe. Delete the Markdown and it is made again; write on the page and it is corrected.
- **Easier:** the agent can do more than transcribe, because it is an agent. Finding where one sitting ends and another begins, and pulling out the lines addressed to an assistant, are the same pass.
- **Harder:** there are now two renderers, `PageRaster` here and `render.py` there. Only `palette.json` holds them together, and nothing tells us when they drift.
- **Harder:** an API key lives on this Mac, in a file that any process running as this person can read. Its scope is `agents:operate` and it is bound to one agent, so what it can reach is small, but it exists and it has to be replaced by hand on another Mac.
- **Harder:** a page is transcribed again every time it is written on, which costs a turn each time.
- **Harder:** a page can now influence *which* agent is offered a line, through what it says. It cannot choose one — the transcriber only proposes, from the assistants a person switched on, and the choice is on screen before anything is sent — but "the model was persuaded by the paper" is a sentence that now has somewhere to land.
- **Harder:** an action carried out is an effect outside this Mac, from a click on a menubar app. It is deliberately never automatic, and there is an undo for every judgement, but "the model misread the line" now costs more than a bad sentence.
- **Committed-to:** the PNG as what the agent transcribes, `pen/<copy>/` as where it finds it, the Markdown beside the strokes, and no memory of what is outstanding.
