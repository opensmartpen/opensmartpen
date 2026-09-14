---
id:
title: Git is a view on the notes, not a step in the flow
status: proposed
tags: [storage, durability, git]
summary: The notes repository stays on this Mac with no remote; a page is safely held the moment its file is written, a commit only shows a person what changed, and both the pen erase and the outstanding list read the files instead of git.
---

# ADR-XXX: Git is a view on the notes, not a step in the flow

**Date:** 2026-09-14
**Status:** Proposed
**Owner:** @matoushavlena

## Context

The notes stay on this Mac. No remote is wanted, so nothing is sent anywhere. A commit therefore moves no data. It makes a second record of a file that is already in the same folder.

A stroke is safe as soon as its line is in the file. The app adds only to the end of a file, and it repairs a line that an interrupted write cut short. A crash after that write loses nothing.

Three questions need an answer, and git answers all three today: what makes a page safe, what lets the pen memory be emptied, and what is still outstanding after a restart.

## Decision

Git has no part in the flow of data. A page is safely held the moment its file is written. A commit only shows a person what changed.

- **The written file is the confirmation.** Nothing waits for a commit before it calls a page safe.
- **The pen is emptied on the written file.** A notebook is deleted from pen memory when its pages are finished and their files are on disk. No commit takes part in that test.
- **What is outstanding comes from the files.** The time on a file says whether its page still waits. Nothing asks git.
- **Capture runs with no git.** If git is absent, or the folder is not a repository, the strokes are still written. Only the commits stop.
- **The repository has no remote.** Nothing is pushed. A copy of the notes to another machine is a later decision, and this record does not make it.

## Areas not covered

- Where the captured files are put, and what they are named.
- When a page counts as finished, and how long it must be quiet first.
- Whether the notes are ever copied off this Mac, and by what means.
- How the readable files are made from the captured files.
- Which tool reads the commits, and what a person does with them.

## Alternatives Considered

- **A commit marks a page as finished** — the mark then needs git installed, the folder kept as a repository for ever, and a subprocess to run before the pen can be emptied.
- **Push to a remote** — not wanted now, and it would make the pen wait for a network to empty.
- **A state file that lists what is outstanding** — a second record beside the files, free to disagree with them.
- **No git at all** — a diff is the cheapest way to see which files a drain or a render touched, and it costs nothing to keep.

## Consequences

- **Easier:** capture stops depending on a subprocess. Each publish runs `git` with a 120 second limit today, and one failure holds the next attempt for up to 30 minutes while the strokes are already on disk.
- **Easier:** the captured files can move to any folder, or to no repository at all, without a new way to mark a page finished.
- **Harder:** the outstanding list is built from file times, which are metadata. A copy of the folder, or any tool that touches a file, can make a finished page look new and publish it a second time.
- **Harder:** "this page was handed on" is no longer written down anywhere. It is worked out from the time on the file each time it is asked for.
- **Harder:** the restart path and the pen erase test both change, and the tests that cover them drive real git in a temporary repository today.
- **Committed-to:** the time on a file as the record of what is outstanding.
