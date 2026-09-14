#!/usr/bin/env python3
"""Transcribe a rendered page into Markdown using Claude.

Reads the PNG that render.py produced and writes a Markdown file beside it, with
frontmatter recording where the text came from and how far it can be trusted. The
image is the evidence: it stays next to the text so anything doubtful can be checked
by eye rather than believed.

Only pages whose rendering is newer than their transcription are redone, so this is
cheap to run repeatedly over every notebook.

Usage:
    transcribe.py <page.png> [--force]
    transcribe.py --all [--root DIR] [--force]
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys

from books import Books, page_dir, parse_raw_path, raw_path

PROMPT = """Transcribe the handwriting in this image into Markdown.

Rules:
- Reproduce what is written, in its original language. Do not translate.
- Do not correct spelling, grammar or arithmetic. Transcribe errors as written.
- Never guess at a word you cannot read. Write `[?]` for an illegible word and
  `[?: your best guess]` when you have one but are unsure.
- Keep the structure the writer used: headings, lists, numbering, indentation,
  checkboxes as `- [ ]` or `- [x]`.
- Describe a drawing or diagram in one italic line, like *[diagram: three boxes
  joined by arrows]*, rather than attempting to draw it.
- Ignore printed page furniture such as rules, dot grids, margins and page numbers.
- Output only the transcription. No preamble, no commentary, no code fences.

Commands: a line the writer began with `>>` is an instruction addressed to an assistant,
not prose. Write each one as a task line, keeping the marker and the wording:

    - [ ] >> the instruction as written

Leave the box empty. Something downstream fills it in. A `>>` in the middle of a line is
not a command; only one that opens the line is.

If the page has no handwriting at all, output exactly: (blank page)"""


# A command line, in any of its states.
COMMAND_RE = re.compile(r"^(?P<lead>\s*[-*]\s*)\[(?P<state>.)\](?P<mark>\s*>>\s*)(?P<text>.+?)\s*$")


def normalise(text: str) -> str:
    return " ".join(text.lower().split())


def command_states(md: str) -> dict[str, str]:
    """What each command in an existing transcription had got to."""
    out = {}
    for line in md.splitlines():
        m = COMMAND_RE.match(line)
        if m and m.group("state") != " ":
            out[normalise(m.group("text"))] = m.group("state")
    return out


def carry_states(text: str, states: dict[str, str]) -> tuple[str, int]:
    """Put previously recorded progress back onto a freshly transcribed page.

    The Markdown is derived: it is rewritten whenever the page is re-rendered, and the
    command is still there on the paper because paper cannot be un-written. Without this,
    every re-transcription would present finished commands as new work.
    """
    if not states:
        return text, 0
    out, carried = [], 0
    for line in text.splitlines():
        m = COMMAND_RE.match(line)
        if m:
            was = states.get(normalise(m.group("text")))
            if was and was != m.group("state"):
                line = f"{m.group('lead')}[{was}]{m.group('mark')}{m.group('text')}"
                carried += 1
        out.append(line)
    return "\n".join(out), carried


def run_claude(image: pathlib.Path, timeout: int = 240) -> tuple[str, str]:
    """Returns (markdown, model). Uses the local Claude Code CLI, so it runs on the
    user's existing login with no API key to manage."""
    prompt = f"Read the image at {image}\n\n{PROMPT}"
    r = subprocess.run(
        ["claude", "-p", prompt, "--output-format", "json"],
        capture_output=True, text=True, timeout=timeout,
    )
    if r.returncode != 0:
        raise RuntimeError(f"claude exited {r.returncode}: {(r.stderr or r.stdout).strip()[:400]}")
    try:
        payload = json.loads(r.stdout)
        text = payload.get("result", "").strip()
        model = payload.get("modelUsage") and next(iter(payload["modelUsage"]), "") or ""
    except json.JSONDecodeError:
        text, model = r.stdout.strip(), ""
    if not text:
        raise RuntimeError("claude returned nothing")
    return strip_fences(text), model


def strip_fences(text: str) -> str:
    """Models sometimes wrap the answer in a fence despite being told not to."""
    m = re.fullmatch(r"```(?:markdown|md)?\n(.*)\n```", text.strip(), re.S)
    return m.group(1).strip() if m else text.strip()


def page_meta(png: pathlib.Path, root: pathlib.Path, books: Books) -> dict:
    """Stroke counts and times, read back from the captured file this page was rendered from."""
    # pages/ sits inside the copy's own folder, so the folder is two levels up from the PNG.
    folder = png.parent.parent.name
    book = books.for_folder(folder)
    # A readable file carries the page name the client used, so the stem *is* the Ncode page.
    m = re.match(r"p(\d+)$", png.stem)
    if not (book and m):
        return {"page": f"{folder}/{png.stem}"}
    ncode = int(m.group(1))
    # The number a person counts to still goes in the frontmatter — it just no longer names a file.
    meta = {"notebook": book.title, "page": str(book.human_page(ncode)),
            "ncode": f"{book.surface}/p{ncode}", "copy": folder}
    raw = raw_path(root, folder, ncode)
    if not raw.exists():
        return meta
    strokes = [json.loads(l) for l in raw.read_text().splitlines() if '"stroke"' in l]
    if not strokes:
        return meta
    iso = lambda t: datetime.datetime.fromtimestamp(t / 1000).isoformat(timespec="seconds")
    meta["strokes"] = len(strokes)
    meta["written_from"] = iso(min(s["start"] for s in strokes))
    meta["written_to"] = iso(max(s["end"] for s in strokes))
    return meta


def frontmatter(meta: dict, model: str, image: pathlib.Path) -> str:
    lines = ["---"]
    for k, v in meta.items():
        lines.append(f"{k}: {v}")
    lines.append(f"image: {image.name}")
    if model:
        lines.append(f"model: {model}")
    lines.append(f"transcribed: {datetime.datetime.now().isoformat(timespec='seconds')}")
    lines.append("source: handwriting; verify against the image before relying on it")
    lines.append("---")
    return "\n".join(lines)


def transcribe(png: pathlib.Path, root: pathlib.Path, books: Books, force: bool) -> None:
    md = png.with_suffix(".md")
    where = f"{png.parent.name}/{png.stem}"
    if md.exists() and not force and md.stat().st_mtime >= png.stat().st_mtime:
        print(f"{where}: up to date")
        return
    states = command_states(md.read_text()) if md.exists() else {}
    try:
        text, model = run_claude(png)
    except Exception as e:
        print(f"{where}: FAILED {e}", file=sys.stderr)
        return
    text, carried = carry_states(text, states)
    md.write_text(frontmatter(page_meta(png, root, books), model, png) + "\n\n" + text + "\n")
    commands = sum(1 for l in text.splitlines() if COMMAND_RE.match(l))
    note = f"{where}: {len(text)} chars -> {md.name}"
    if commands:
        note += f"   {commands} command(s)" + (f", {carried} carried" if carried else "")
    print(note)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("png", nargs="?", help="a rendered page .png")
    ap.add_argument("--all", action="store_true", help="transcribe every rendered page")
    ap.add_argument("--root", default="~/Brainio/pen", help="where the notes are kept")
    ap.add_argument("--force", action="store_true", help="redo even if the transcription is current")
    a = ap.parse_args()

    root = pathlib.Path(a.root).expanduser()
    books = Books(root)
    if a.all:
        pngs = sorted(root.glob("books/*/pages/*.png"))
        if not pngs:
            raise SystemExit(f"no rendered pages under {root / 'books'}; run render.py --png first")
        for p in pngs:
            transcribe(p, root, books, a.force)
    elif a.png:
        p = pathlib.Path(a.png).expanduser()
        transcribe(p, root, books, a.force)
    else:
        ap.error("give a png or --all")


if __name__ == "__main__":
    main()
