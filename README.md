<p align="center">
  <img src="assets/logo.png" width="96" alt="Open Smart Pen">
</p>

<h1 align="center">Open Smart Pen</h1>

<p align="center">
  <strong>You write. Your agent acts.</strong><br>
  A free, open-source Mac app that gives your handwritten pages to your own AI agent.
</p>

<p align="center">
  <a href="https://opensmartpen.org/">Website</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

Open Smart Pen is a small app in the macOS menu bar. It captures what a smartpen writes on paper and keeps each page as plain files in a folder on your Mac. Your agent, for example Claude Code or Codex, reads the pages and does the rest: it transcribes them, makes tasks, writes messages, builds what you sketched.

The app does one job. It does not transcribe, it has no account, and it never sends us what you write. It can report how it is used and what goes wrong, and that is off unless you turn it on. See [Telemetry](#telemetry).

<p align="center">
  <img src="assets/panel.png" width="320" alt="The Open Smart Pen panel: two pens, two agents and three notebooks">
</p>

## How it works

1. **You write** on paper with a smartpen. The pen sends each stroke to your Mac over Bluetooth. Away from the Mac, the pen keeps the pages and sends them when it is back.
2. **The app keeps each page** in `~/OpenSmartPen`: the strokes, with the time of each one, and a picture of the page. If you connect an S3 bucket, it copies the same files there.
3. **Your agent reads the pages.** One small file says when a page changed, so an agent can check often at almost no cost. The agent writes the text of each page back, and the app shows it beside the ink.

You do not need a pen to try it. The app also takes a photo of a handwritten page, from an iPhone or from a file.

## What you need

- A Mac with macOS 13 or later.
- An agent that can read files: Claude Code, Codex, or another one. An agent in the cloud works too, with the S3 bucket.
- A Neo smartpen and Ncode paper, or a photo of any handwritten page.

Tested with the Neo smartpen A1 and the LAMY Safari Ncode, on NeoLAB Ncode A4 paper and LAMY digital paper.

## Get started

### 1. Install the app

Download the newest [`OpenSmartPen-<version>.dmg`](https://github.com/opensmartpen/opensmartpen/releases/latest), open it, and drag Open Smart Pen to the Applications folder. Then open the app.

- macOS asks one time for the Bluetooth permission. Allow it; without it the pen cannot connect.
- The app is in the menu bar, as a pencil. It has no window of its own and no icon in the Dock.
- The app starts when you log in, and it updates itself. A new version installs with no window, at a moment when no pen is writing. Settings → About has the switch for this, and "Check for Updates…".

The download is signed by Apoco s.r.o. and notarised by Apple.

To build the app from the source, see [`app/README.md`](app/README.md).

### 2. Add a page

- **With a pen:** switch the pen on near your Mac. The app pairs with the first pen it sees. Then write.
- **Without a pen:** click the pencil in the menu bar, then "Add Photo…". Take a photo with your iPhone, select a file, or use the sample page.

### 3. Connect your agent

Click the pencil in the menu bar, then "Copy instructions", and paste the sentence into your agent. It looks like this:

> Read https://opensmartpen.org/llms.txt and set yourself up to transcribe my Open Smart Pen pages. The pages are in the folder ~/OpenSmartPen on my Mac.

The agent reads the setup text, writes its name beside your pages, and transcribes what is there. The app then shows the agent in the panel, and the text of each page in the viewer.

The app never starts an agent. Your agent decides when it runs.

## Where your pages go

All files are in `~/OpenSmartPen`, outside the app. You can delete the app and install it again, and no page is lost.

```
last-modified.txt             when a page last changed: the one file an agent watches
books/<copy>/book.json        the name of the notebook and its paper size
books/<copy>/raw/p<N>.jsonl   the strokes of one page, with the time of each stroke
books/<copy>/pages/p<N>.png   a picture of that page
transcripts/<copy>/p<N>.md    the text of the page, written by your agent
agents/<n>.json               each agent's name, and when it was last alive
```

- **Your pages go nowhere by themselves.** With no bucket connected, all files stay on your Mac.
- **An S3 bucket is optional.** Connect one in Settings → Sync if your agent runs on a different computer. Amazon S3 and services with the same interface work, for example Cloudflare R2 and MinIO.
- **Your agent uses its own model.** When it reads a page, it sends the picture of the page to that model, as it does with any file you give it.

[`docs/processing.md`](docs/processing.md) is the full contract between the app and an agent: what the app writes, where, and when.

## Telemetry

The app can send its makers how it is used and what goes wrong: which buttons are clicked, how many pages are synced, the Bluetooth address of each pen, errors and crashes. It never sends what you write, your pages, their text, the names of your notebooks and pens, or anything about your bucket.

- **It is off unless you turn it on,** in Settings → General. You can turn it off again at any time.
- **This version sends nothing to us.** The project has no collector yet. Turned on, the app sends to a collector on your own Mac (`http://localhost:4318`), unless the config names another.
- **A later version will have it on unless you turn it off.** A window will say so before anything is sent, and it has a "Turn Off" button.

[`docs/telemetry.md`](docs/telemetry.md) lists each thing that is sent.

## Documentation

| Document | What it is |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | The system, and the entry point to all other documents |
| [`docs/processing.md`](docs/processing.md) | The contract with an agent: the files, their order, how to read time |
| [`docs/agent-install.md`](docs/agent-install.md) | The text an agent sets itself up from |
| [`docs/telemetry.md`](docs/telemetry.md) | What the app reports to its makers, and how to turn it off |
| [`docs/stroke-format.md`](docs/stroke-format.md) | The format of the stroke files |
| [`docs/ubiquitous-language.md`](docs/ubiquitous-language.md) | The glossary |
| [`app/README.md`](app/README.md) | How to build, install and debug the app |

## Status

The project is new. The current version is 0.2.0.

- It works each day with the two pens and the two papers named above. Other Neo pens and Ncode notebooks probably work, but nobody tested them.
- Only Neo smartpens are supported. The pen code is in three files, so a different pen is possible, but there is no interface for it yet.
- macOS only.

## Contributing

Bug reports and ideas are welcome. Open an issue first, so that we can agree on the change before you write code. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for the rules and for how to build and test.

## License

- The source code in this repository is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).
- The app links NISDK3, the pen SDK of NeoLAB, which is licensed under GPL-3.0. A built copy of the app is thus distributed under GPL-3.0 as a whole. See [`NOTICE`](NOTICE).
- NISDK3 is not in this repository. The build downloads it.

Open Smart Pen is not affiliated with NeoLAB Convergence, Inc. "Neo smartpen" and "Ncode" are trademarks of NeoLAB Convergence, Inc.
