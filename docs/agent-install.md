# Set up an agent for Open Smart Pen

This text is for an AI agent. A person gave you a link to it and told you where their pages are. Do the setup with them, once. Then keep the rules below in your own memory or instructions. You do not need to read this text again unless the version changes.

Version of these rules: **1**.

## What Open Smart Pen is

A Mac app that captures what a smartpen writes on paper. It writes each page as a picture. It does not turn handwriting into text. That is your job.

The pages are in one of two places, with the same layout:

- a folder on the person's Mac, usually `~/OpenSmartPen`;
- an S3 bucket, if the person connected one.

Use the folder if you run on that Mac. Use the bucket if you run somewhere else. Use one of them, not both.

## The layout

```
last-modified.txt             the one file to watch (see below)
books/<copy>/book.json        notebook title, paper size, first_page
books/<copy>/raw/p<N>.jsonl   strokes of one page, with the time of each stroke
books/<copy>/pages/p<N>.png   picture of that page
transcripts/                  yours: one text file for each page
agents/<n>.json               yours: who you are, and when you were last alive
```

The app writes all of it except `transcripts/` and `agents/`. Do not write under `books/`. Ignore `books/s3-o1013-b1-*` (a printed control strip, not notes), `pens/`, `mode.jsonl` and `palette.json`.

Not each page comes from a pen. The notebook "Photos" holds pages that arrived as a picture. Such a page has no strokes: its `raw/p<N>.jsonl` has one line `"t":"image"` that names the picture as it arrived, in the same folder. Its page picture is in `pages/` as for each other page, and you transcribe it the same way. The notebook exists only when the person added a picture. Its first page can be a sample page that the app offers.

## Setup, once

1. **Find the pages.** Confirm that you can read `last-modified.txt` and write under `transcripts/` and `agents/`. If you cannot, tell the person what access is missing and stop.
2. **Say who you are.** Take the first number `n`, from 0, for which `agents/<n>.json` does not exist, and write that file:

   ```
   {"name": "Claude Code", "alive": "2026-11-14T09:12:33Z", "url": "https://..."}
   ```

   `name` is what the person sees in the app. `alive` is the time now, in UTC. `url` is optional: a web address where the person can see you, which the app opens on a click. The app shows "Connect your agent" until this file is there, and reads it again each minute. Tell the person to look.
3. **Transcribe what is owed.** Do one run now, by the rules below, so the person sees text for the pages they have. If there is no page yet, tell the person to add one: the app takes a photo of handwriting from an iPhone or a file, and offers a sample page.
4. **Arrange your own wake-up.** The app never starts you. Use the cheapest way you have:
   - If you can run commands on the Mac: a small launchd job with a shell script. The script reads `last-modified.txt`, compares it with the value from the last run, sets `alive` in your agent file, and starts you only when the value changed. A check then costs no tokens. Make sure that you can run without a window and without a permission prompt, or you will stop at the first one.
   - If you cannot: use your own scheduled task, and make the check of `last-modified.txt` your first step.
5. **Keep the rules.** Store the section "Each run", your number `n` and the version number where you keep instructions. Tell the person what you set up and how to stop it.

## Each run

1. Read `last-modified.txt`. It has two lines:

   ```
   changed: 2026-11-14T09:12:33.123Z
   rules: 1
   ```

2. If `rules:` is not the version you have, read this text again before you continue.
3. Compare `changed:` with the value you saw at your last run. If it is the same, stop. Do not compare it with the clock: a pen used away from the Mac sends its pages hours later, and the time is then hours old.
4. If it is different, find the pages that are owed. A page is owed when `books/<copy>/pages/p<N>.png` has no `transcripts/<copy>/p<N>.md`, or is newer than it. The time file says "look now". It does not say which pages.
5. For each owed page, write the transcript (see below). Then store the new `changed:` value.
6. Set `alive` in your `agents/<n>.json` to the time now. Do this at each run, also when nothing changed, if it costs you nothing. The app shows you in grey when the pages changed more than two hours ago and your `alive` is older than that change. It does not hold silence against you when there was nothing to do.

The first time, and from time to time, do step 4 without step 3, so that a page is never missed.

## The transcript

- One file for each page: `transcripts/<copy>/p<N>.md`, with the same `<copy>` and `<N>` as the picture.
- Write the full page as plain text. No summary and no cleanup. Keep the line breaks.
- Read your last transcript of that page first. A page is written on again and again, and the picture always shows the whole page. Keep the earlier text stable and add what is new.
- **Always write a transcript**, also for a page you cannot read. Write what you can and say what you could not. A page with no transcript stays owed, and you will pay for it at each run.
- The app shows the file beside the ink. It draws `# ` as a title, `## ` as a heading, `- ` as a bullet, and emphasis inside a line. All other text is shown as it is.

## Time

- When a page was written is in `raw/p<N>.jsonl`. Each line with `"t":"stroke"` has `start` and `end` in epoch milliseconds. The lines are not in time order; sort by `start`.
- One page can hold writing from several days. Group the strokes by gaps in time if the person wants to know what was written when.
- The page number for people is `N - first_page + 1`, and the notebook name is `title`, both from `book.json`.
