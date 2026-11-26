# Set up an agent for Open Smart Pen

This text is for an AI agent. A person sent you here and told you where their pages are. Do the setup with them, once. Then keep the rules below in your own memory or instructions. You do not need to read this text again unless the version changes.

Version of these rules: **1**.

## What Open Smart Pen is

A Mac app that captures what a smartpen writes on paper. It writes each page as a picture. It does not turn handwriting into text. That is your job.

The pages are in one of two places, with the same layout:

- a folder on the person's Mac, usually `~/OpenSmartPen`;
- an S3 bucket, if the person connected one.

Use the folder if you run on that Mac. Use the bucket if you run somewhere else. Use one of them, not both.

If you run somewhere else and the person gave you no bucket, stop. You cannot read the folder, and you cannot connect a bucket: only the person can, in the app, in Settings, under "Sync". Tell them to connect a bucket there, then to give you its address and a key. If they have no bucket, tell them that Amazon S3 and each service with the same interface work, for example Cloudflare R2 and Supabase.

## The layout

```
last-modified.txt             the one file to watch (see below)
books/<copy>/book.json        notebook title, paper size, first_page
books/<copy>/raw/p<N>.jsonl   strokes of one page, with the time of each stroke
books/<copy>/pages/p<N>.png   picture of that page
transcripts/                  yours: one text file for each page
agents/<n>.json               yours: who you are, and when you were last alive
```

The app writes all of it except `transcripts/` and `agents/`. In this folder or bucket you write two things: the transcript of each page, and your one file `agents/<n>.json`. Keep each other file of yours in your own place. Do not change or delete a file that the app wrote. Ignore `pens/`, `mode.jsonl` and `palette.json`.

Not each page comes from a pen. The notebook "Photos" holds pages that arrived as a picture. Such a page has no strokes: its `raw/p<N>.jsonl` has one line, `{"t":"image","file":"p<N>.jpg","added":<ms>,"taken":<ms>}`, with the times in epoch milliseconds. `file` is the picture as it arrived, in the same folder. `taken` is when the photo was taken; it is absent when the app does not know. `added` is when the picture came into the app. Use `taken` as the time of the page, and `added` when there is no `taken`. Treat the page as one piece of writing at that time: a photo does not say when each line was written. Its page picture is in `pages/` as for each other page, and you transcribe it the same way. The notebook exists only when the person added a picture. A page in it can be a sample page that the app offers.

## Setup, once

1. **Find the pages.** Confirm that you can read `last-modified.txt` and write under `transcripts/` and `agents/`. If you cannot, tell the person what access is missing and stop.
2. **Say who you are.** Take the first number `n`, from 0, for which `agents/<n>.json` does not exist, and write that file:

   ```
   {"name": "Claude Code", "alive": "2026-11-14T09:12:33Z", "url": "https://..."}
   ```

   `name` is what the person sees in the app. `alive` is the time now, in UTC. `url` is a web address where the person can open you, for example your chat. Give one if you have one: the app shows it as a way to open you from its panel. Leave the field out only when no such address exists. The app shows "Connect your agent" until this file is there, and reads it again each minute. Tell the person to look.
3. **Transcribe what is owed.** Do one run now, by the rules below, so the person sees text for the pages they have. If there is no page yet, tell the person to add one: the app takes a photo of handwriting from an iPhone or a file, and offers a sample page.
4. **Arrange your own wake-up.** The app never starts you. How you do it is your decision. This is the goal:
   - **A check must cost no tokens while nothing changed.** The check is: read `last-modified.txt`, and compare `changed:` with the value from the last check. No model is necessary for that.
   - **Check often.** Each minute is good. The person wants the text some seconds after they stop writing, not after an hour.
   - **If you can run scripts on the Mac,** write a small script that does the check and starts you, with no window, only when the value changed. Let the system run it each minute, or when the folder changes. Make sure that you can run without a window and without a permission prompt, or you will stop at the first one. The script also sets `alive` in your agent file.
   - **If you cannot run scripts,** use your own schedule, as short as it allows, and make the check your first step, so that a run with nothing new stops at once.
   - **If you had a schedule before,** make it shorter now. A schedule of 30 minutes was right when each run read all pages. With the check, a run with nothing new costs almost nothing, so some minutes is right.
   - **Do not let two runs work at the same time.** If one run is still at work when the next check comes, the next one stops.
   - Test it before you say that you are done: change nothing and confirm that the check stops; then ask the person to add a page and confirm that you start.
5. **Keep the rules in one file.** Make one text file of instructions for these pages, in your own place, and read it at the start of each run. Put in it: the section "Each run", your number `n` and the version number. It also has a part "The person's rules", empty at the start. Tell the person what you set up and how to stop it.

## When the person gives you a rule

The person can give you a rule for their pages in one sentence, for example "from now on, keep my to-dos in Apple Reminders". Then:

- Add the sentence to "The person's rules" in your file of instructions, in the person's words. Tell the person that you did it.
- Do nothing else. Do not write a program for the rule, do not change your wake-up, and do not go through the pages now.
- At each run, after the transcript of a page, apply each rule to that page with your own judgement. A rule applies only to pages that you transcribe from now on, not to old pages.

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
- **Write it at once.** Do not hold a page back while you wait for something else, such as the name of a meeting. Write the text now, and add the rest in a later run. The person looks for the text in the app some minutes after they stop writing.
- **A page you decide not to transcribe** also gets a transcript: one line that says so, for example for pages that were written before you were set up. Without it the page stays owed.
- The app shows the file beside the ink. It draws `# ` as a title, `## ` as a heading, `- ` as a bullet, and emphasis inside a line. All other text is shown as it is.

## Time

- When a page was written is in `raw/p<N>.jsonl`. Each line with `"t":"stroke"` has `start` and `end` in epoch milliseconds. The lines are not in time order; sort by `start`.
- One page can hold writing from several days. Group the strokes by gaps in time if the person wants to know what was written when.
- The page number for people is `N - first_page + 1`, and the notebook name is `title`, both from `book.json`.
