#!/usr/bin/env python3
"""Transcribe a rendered page into Markdown using Claude.

Reads the PNG that render.py produced and writes a Markdown file beside it, with
frontmatter recording where the text came from and how far it can be trusted. The
image is the evidence: it stays next to the text so anything doubtful can be checked
by eye rather than believed.

Only pages whose rendering is newer than their transcription are redone, so this is
cheap to run repeatedly over a whole repository.

Usage:
    transcribe.py <page.png> [--force]
    transcribe.py --all [--repo DIR] [--force]
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys

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

If the page has no handwriting at all, output exactly: (blank page)"""


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


def page_meta(png: pathlib.Path, repo: pathlib.Path) -> dict:
    """Stroke counts and times, read back from the raw file this page was rendered from."""
    m = re.search(r"(s\d+)/(o\d+)/(b\d+)/(p\d+)\.png$", str(png))
    if not m:
        return {}
    rel = "/".join(m.group(1, 2, 3, 4))
    raw = repo / "raw" / f"{rel}.jsonl"
    if not raw.exists():
        return {"page": rel}
    strokes = [json.loads(l) for l in raw.read_text().splitlines() if '"stroke"' in l]
    if not strokes:
        return {"page": rel}
    first = min(s["start"] for s in strokes) / 1000
    last = max(s["end"] for s in strokes) / 1000
    iso = lambda t: datetime.datetime.fromtimestamp(t).isoformat(timespec="seconds")
    return {"page": rel, "strokes": len(strokes), "written_from": iso(first), "written_to": iso(last)}


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


def transcribe(png: pathlib.Path, repo: pathlib.Path, force: bool) -> None:
    md = png.with_suffix(".md")
    if md.exists() and not force and md.stat().st_mtime >= png.stat().st_mtime:
        print(f"{png.parent.name}/{png.stem}: up to date")
        return
    try:
        text, model = run_claude(png)
    except Exception as e:
        print(f"{png.parent.name}/{png.stem}: FAILED {e}", file=sys.stderr)
        return
    md.write_text(frontmatter(page_meta(png, repo), model, png) + "\n\n" + text + "\n")
    first = next((l for l in text.splitlines() if l.strip()), "")
    print(f"{png.parent.name}/{png.stem}: {len(text)} chars -> {md.name}   {first[:60]}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("png", nargs="?", help="a rendered page .png")
    ap.add_argument("--all", action="store_true", help="transcribe every rendered page")
    ap.add_argument("--repo", default="~/PenBridge/notes", help="notes repository")
    ap.add_argument("--force", action="store_true", help="redo even if the transcription is current")
    a = ap.parse_args()

    repo = pathlib.Path(a.repo).expanduser()
    if a.all:
        pngs = sorted((repo / "pages").rglob("*.png"))
        if not pngs:
            raise SystemExit(f"no rendered pages under {repo / 'pages'}; run render.py --png first")
        for p in pngs:
            transcribe(p, repo, a.force)
    elif a.png:
        p = pathlib.Path(a.png).expanduser()
        transcribe(p, repo, a.force)
    else:
        ap.error("give a png or --all")


if __name__ == "__main__":
    main()
