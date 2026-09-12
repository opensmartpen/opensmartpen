#!/usr/bin/env python3
"""Render raw pen strokes to SVG (and optionally PNG).

Reads one page's append-only JSONL file (docs/stroke-format.md) and draws it at true
physical size. Coordinates arrive in Ncode cells; one cell is 2.371 mm.

Geometry: a page needs to know which paper it is printed on before it can be drawn to
scale. NeoLAB publishes no layout file for our notebooks, so the paper is taken from
geometry/<book>.json when present and otherwise guessed from the strokes themselves.

Usage:
    render.py <raw.jsonl> [-o out.svg] [--png] [--repo DIR]
    render.py --all [--repo DIR] [--png]
"""

from __future__ import annotations

import argparse
import bisect
import json
import pathlib
import sys

from books import Books, Pens, page_dir, page_stem, parse_raw_path

MM_PER_CELL = 2.371

# Width of the ink line in millimetres at middling pressure, i.e. what the refill actually lays
# down, not the diameter of the ball. Measured against Neo Studio, which exports each stroke as a
# filled outline rather than a stroked path: its default black came to 0.29 mm, so 0.25 here lands
# on the same line once pressure widens it. Override with --nib.
NIB_MM = 0.25

# Paper sizes in millimetres, widest first, used when a book has no recorded geometry.
PAPERS = {
    "A4": (210.0, 297.0),
    "A5": (148.0, 210.0),
    "Letter": (215.9, 279.4),
}


# Ncode books that are printed control surfaces rather than paper. Mirrors Config.controlBooks in
# PenBridge; taps on them are stored in raw as evidence but are never pages, so they are not drawn.
CONTROL_BOOKS = {"s3/o1013/b1"}


class Stroke:
    __slots__ = ("start", "end", "color", "tip", "dots", "src", "nib", "ink_name", "pen")

    def __init__(self, o: dict):
        self.start = o["start"]
        self.end = o["end"]
        # The pen always stamps black: it has no idea what the paper controller selected, and
        # NISDK3 cannot tell it. Colour is decided here, from the mode log.
        self.color = o.get("color", "#000000")
        self.tip = o.get("tip", "pen")
        self.src = o.get("src", "live")
        self.dots = o["dots"]
        self.nib = NIB_MM
        self.ink_name = None
        self.pen = o.get("pen")


def read_page(path: pathlib.Path) -> list[Stroke]:
    """Strokes sorted by time. Raw lines arrive in capture order, which is not chronological:
    strokes buffered just before a connection completes are appended after live ones."""
    strokes = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        o = json.loads(line)
        if o.get("t") == "stroke" and o.get("dots"):
            strokes.append(Stroke(o))
    strokes.sort(key=lambda s: s.start)
    return strokes


def load_palette(repo: pathlib.Path) -> dict:
    """Ink hexes and line widths, from the repo rather than from code, so the panel and the
    renderer cannot disagree about what `red` looks like."""
    path = repo / "palette.json"
    if not path.exists():
        return {"ink": {}, "width_mm": {}}
    return json.loads(path.read_text())


def load_modes(repo: pathlib.Path) -> list[dict]:
    """Every ink and width change, oldest first *by its own timestamp*.

    The file is not in time order. A tap made away from the Mac waits in pen memory and is
    appended at the next drain, long after events that happened later. Each line therefore records
    only what changed, and the state at any moment is the replay of everything at or before it.
    """
    path = repo / "raw" / "mode.jsonl"
    if not path.exists():
        return []
    events = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        o = json.loads(line)
        if o.get("t") == "mode":
            events.append(o)
    events.sort(key=lambda e: e["at"])
    return events


DEFAULT_INK, DEFAULT_WIDTH = "black", "default"


def load_timeline(repo: pathlib.Path) -> list[int]:
    """Every stroke start time in the repo, sorted, taps included.

    The pen returns to its defaults after a long enough gap in writing, and that gap is measured
    between consecutive strokes anywhere — not within a page. Turning a page is not a reset, and
    writing on page 3 after page 7 is not one either. Nothing records the reset: every stroke
    already carries an absolute timestamp, so the boundary is derived, and there is no third
    writer to keep in step.

    Taps count as writing here. Otherwise tapping red after a week away, then writing, would put
    the boundary *after* the tap and throw the colour away — which is the opposite of what the
    person just asked for.
    """
    starts = []
    for f in (repo / "raw").rglob("*.jsonl"):
        if f.name == "mode.jsonl":
            continue
        for line in f.read_text().splitlines():
            if not line.strip():
                continue
            o = json.loads(line)
            if o.get("t") == "stroke" and o.get("dots"):
                starts.append(o["start"])
    starts.sort()
    return starts


def reset_boundaries(timeline: list[int], gap_hours: float) -> list[int]:
    """The moments at which writing resumed after a long enough silence. Everything chosen before
    such a moment stops applying: a colour picked last week must not still be in force today."""
    gap_ms = gap_hours * 3600_000
    return [t for prev, t in zip(timeline, timeline[1:]) if t - prev > gap_ms]


def apply_modes(strokes: list[Stroke], events: list[dict], palette: dict, nib_mm: float,
                boundaries: list[int] | None = None, pens: Pens | None = None) -> list[str]:
    """Give each stroke the ink and width in force when it was written. Returns any complaints."""
    inks, widths = palette.get("ink", {}), palette.get("width_mm", {})
    typical = typical_multiplier(palette.get("pressure"))
    boundaries = boundaries or []
    unmeasured = set()
    for s in strokes:
        # Everything chosen since writing last resumed, and nothing from before it.
        since = boundaries[bisect.bisect_right(boundaries, s.start) - 1] if boundaries and boundaries[0] <= s.start else None
        # Writing starts from the pen's own defaults, not from a constant: a pen kept for
        # accents is not a black pen that someone keeps re-selecting.
        ink_name, width_name = pens.defaults(s.pen) if pens else (DEFAULT_INK, DEFAULT_WIDTH)
        for e in events:
            if e["at"] > s.start:
                break
            if since is not None and e["at"] < since:
                continue
            ink_name = e.get("ink", ink_name)
            width_name = e.get("width", width_name)
        s.ink_name = ink_name
        hex_value = inks.get(ink_name)
        if hex_value:
            s.color = hex_value
        elif ink_name != DEFAULT_INK:
            unmeasured.add(ink_name)
        s.nib = widths[width_name] / typical if width_name in widths else nib_mm
    return [f"ink '{n}' is unmeasured, drawn black" for n in sorted(unmeasured)]


def guess_geometry(strokes: list[Stroke]) -> dict:
    """Fall back to a whole sheet of the smallest standard paper the writing fits on.

    The Ncode origin sits at the top-left of the printed pattern, so cell coordinates are
    already page-relative: the paper is (0,0) to (width, height) in cells. This is a guess,
    flagged as such, until a book is calibrated.
    """
    xs = [d[0] for s in strokes for d in s.dots]
    ys = [d[1] for s in strokes for d in s.dots]
    need_w, need_h = max(xs) * MM_PER_CELL, max(ys) * MM_PER_CELL
    for name, (w, h) in sorted(PAPERS.items(), key=lambda kv: kv[1][0] * kv[1][1]):
        if need_w <= w and need_h <= h:
            return {"paper": name, "width_mm": w, "height_mm": h, "source": "guessed"}
    w, h = PAPERS["A4"]
    return {"paper": "A4", "width_mm": w, "height_mm": h, "source": "guessed (overflows)"}


# The pressure curve, and the multiplier at typical writing force. Both come from palette.json so
# that the renderer, the live view and anything else drawing ink use one definition; PRESSURE is
# only the fallback for a repo that has no palette yet.
PRESSURE = {"base": 0.65, "range": 0.7, "typical_force": 0.7}


def width_for(force: float, base: float, pressure: dict | None = None) -> float:
    """Nib width in mm. Force is 0..1 and mostly sits mid-range, so the spread is gentle:
    a 0.5 mm gel nib does not double in width when pressed."""
    p = pressure or PRESSURE
    return base * (p["base"] + p["range"] * max(0.0, min(1.0, force)))


def typical_multiplier(pressure: dict | None = None) -> float:
    """What width_for returns at typical writing force, as a multiple of the base. palette.json
    records the width actually drawn, so dividing by this gives the base the renderer wants."""
    p = pressure or PRESSURE
    return p["base"] + p["range"] * p["typical_force"]


def path_data(dots: list, decimals: int = 2) -> str:
    pts = [(d[0] * MM_PER_CELL, d[1] * MM_PER_CELL) for d in dots]
    if len(pts) == 1:
        x, y = pts[0]
        return f"M{x:.{decimals}f},{y:.{decimals}f}l0.01,0"
    # Catmull-Rom through the samples, converted to cubic Béziers, so the ink curves the way
    # the nib moved instead of showing the 12 ms polling as corners.
    out = [f"M{pts[0][0]:.{decimals}f},{pts[0][1]:.{decimals}f}"]
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else pts[i]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else p2
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        out.append(
            f"C{c1[0]:.{decimals}f},{c1[1]:.{decimals}f} "
            f"{c2[0]:.{decimals}f},{c2[1]:.{decimals}f} "
            f"{p2[0]:.{decimals}f},{p2[1]:.{decimals}f}"
        )
    return "".join(out)


def render_svg(strokes: list[Stroke], geom: dict, nib_mm: float = NIB_MM, crop: bool = False) -> str:
    w, h = geom["width_mm"], geom["height_mm"]
    ox = oy = 0.0
    if crop:
        xs = [d[0] * MM_PER_CELL for s in strokes for d in s.dots]
        ys = [d[1] * MM_PER_CELL for s in strokes for d in s.dots]
        pad = 5.0
        ox, oy = max(0.0, min(xs) - pad), max(0.0, min(ys) - pad)
        w, h = min(w, max(xs) + pad) - ox, min(h, max(ys) + pad) - oy

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.2f}mm" height="{h:.2f}mm" '
        f'viewBox="{ox:.2f} {oy:.2f} {w:.2f} {h:.2f}">',
        f'<rect x="{ox:.2f}" y="{oy:.2f}" width="{w:.2f}" height="{h:.2f}" fill="#ffffff"/>',
        '<g fill="none" stroke-linecap="round" stroke-linejoin="round">',
    ]
    for s in strokes:
        if s.tip == "eraser":
            continue
        # One path per run of similar pressure keeps the file small while still varying width.
        runs, cur, cur_w = [], [s.dots[0]], width_for(s.dots[0][2], s.nib)
        for d in s.dots[1:]:
            wd = width_for(d[2], s.nib)
            if abs(wd - cur_w) > s.nib * 0.12:
                cur.append(d)
                runs.append((cur, cur_w))
                cur, cur_w = [d], wd
            else:
                cur.append(d)
        runs.append((cur, cur_w))
        for dots, wd in runs:
            parts.append(f'<path d="{path_data(dots)}" stroke="{s.color}" stroke-width="{wd:.3f}"/>')
    parts.append("</g></svg>")
    return "\n".join(parts)


def content_box(strokes: list[Stroke], pad_mm: float = 6.0) -> tuple[float, float, float, float]:
    xs = [d[0] * MM_PER_CELL for s in strokes for d in s.dots]
    ys = [d[1] * MM_PER_CELL for s in strokes for d in s.dots]
    return (min(xs) - pad_mm, min(ys) - pad_mm, max(xs) + pad_mm, max(ys) + pad_mm)


def render_png(strokes: list[Stroke], png_path: pathlib.Path, nib_mm: float = NIB_MM,
               dpi: float = 200, max_px: int = 2200, min_px: int = 700, ss: int = 3) -> bool:
    """Rasterise the written area straight from the strokes.

    Cropped to the writing rather than the whole sheet: this image is what a vision model
    reads, and a line of text marooned in an A4 of white space transcribes badly. The SVG
    beside it keeps the true page. Drawn at `ss` times the target size and scaled down,
    because PIL has no anti-aliasing of its own.
    """
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("  png needs Pillow (pip install pillow)", file=sys.stderr)
        return False

    x0, y0, x1, y1 = content_box(strokes)
    w_mm, h_mm = x1 - x0, y1 - y0
    scale = dpi / 25.4
    longest = max(w_mm, h_mm) * scale
    if longest > max_px:
        scale *= max_px / longest
    elif longest < min_px:
        scale *= min_px / longest

    w = max(1, round(w_mm * scale)) * ss
    h = max(1, round(h_mm * scale)) * ss
    img = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(img)

    def pt(dot):
        return ((dot[0] * MM_PER_CELL - x0) * scale * ss, (dot[1] * MM_PER_CELL - y0) * scale * ss)

    for s in strokes:
        if s.tip == "eraser":
            continue
        pts = [pt(dd) for dd in s.dots]
        widths = [max(1.0, width_for(dd[2], s.nib) * scale * ss) for dd in s.dots]
        if len(pts) == 1:
            r = widths[0] / 2
            d.ellipse([pts[0][0] - r, pts[0][1] - r, pts[0][0] + r, pts[0][1] + r], fill=s.color)
            continue
        for i in range(len(pts) - 1):
            lw = (widths[i] + widths[i + 1]) / 2
            d.line([pts[i], pts[i + 1]], fill=s.color, width=max(1, round(lw)))
            # Round the joins by hand; PIL's line joins are square.
            r = lw / 2
            d.ellipse([pts[i + 1][0] - r, pts[i + 1][1] - r, pts[i + 1][0] + r, pts[i + 1][1] + r], fill=s.color)

    png_path.parent.mkdir(parents=True, exist_ok=True)
    img.resize((max(1, w // ss), max(1, h // ss)), Image.LANCZOS).save(png_path)
    return True


def render_file(raw: pathlib.Path, repo: pathlib.Path, books: Books, out: pathlib.Path | None,
                png: bool, crop: bool, nib_mm: float = NIB_MM,
                palette: dict | None = None, modes: list[dict] | None = None,
                boundaries: list[int] | None = None, pens: Pens | None = None) -> None:
    book_id, ncode_page = parse_raw_path(raw)
    if book_id in CONTROL_BOOKS:
        print(f"{book_id}/p{ncode_page}: control surface, not a page")
        return
    book = books.for_id(book_id)
    strokes = read_page(raw)
    if not strokes:
        print(f"{book_id}/p{ncode_page}: no strokes")
        return
    palette = palette if palette is not None else load_palette(repo)
    modes = modes if modes is not None else load_modes(repo)
    if boundaries is None:
        boundaries = reset_boundaries(load_timeline(repo), palette.get("reset_after_hours", 24))
    complaints = apply_modes(strokes, modes, palette, nib_mm, boundaries, pens or Pens(repo))
    if book and book.has_geometry:
        geom = {"paper": book.title, "width_mm": book.width_mm,
                "height_mm": book.height_mm, "source": book.source}
    else:
        geom = guess_geometry(strokes)

    # One raw file can hold two physical notebooks. A book code identifies a product, so a second
    # pad of the same kind writes to the same addresses; the instance boundary is what separates
    # them, and each copy gets its own directory rather than overwriting the last one's pages.
    groups: dict[str, list[Stroke]] = {}
    for st in strokes:
        groups.setdefault(book.instance_at(st.start) if book else book_id, []).append(st)

    stem = page_stem(book, ncode_page)
    for slug, group in groups.items():
        svg_path = out or (repo / "pages" / slug / f"{stem}.svg")
        svg_path.parent.mkdir(parents=True, exist_ok=True)
        svg_path.write_text(render_svg(group, geom, nib_mm=nib_mm, crop=crop))
        where = f"{slug}/{stem}"
        note = f"{where}: {len(group)} strokes -> {svg_path.name}  [{geom['paper']}]"
        if png:
            note += "  +png" if render_png(group, svg_path.with_suffix(".png"), nib_mm=nib_mm) else "  (png failed)"
        print(note)
        for c in complaints:
            print(f"  {where}: {c}")
        if out and len(groups) > 1:
            others = ", ".join(sorted(set(groups) - {slug}))
            print(f"  only this copy was rendered; -o names one file. Also in this page: {others}",
                  file=sys.stderr)
        if out:
            break


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw", nargs="?", help="a raw page .jsonl file")
    ap.add_argument("--all", action="store_true", help="render every raw page in the repo")
    ap.add_argument("--repo", default="~/PenBridge/notes", help="notes repository")
    ap.add_argument("-o", "--out", help="output .svg path (single file only)")
    ap.add_argument("--png", action="store_true", help="also write a PNG next to the SVG")
    ap.add_argument("--crop", action="store_true", help="trim to the written area instead of the whole sheet")
    ap.add_argument("--nib", type=float, default=NIB_MM, help=f"ink width in mm at middling pressure (default {NIB_MM})")
    a = ap.parse_args()

    repo = pathlib.Path(a.repo).expanduser()
    books = Books(repo)
    palette, modes = load_palette(repo), load_modes(repo)
    boundaries = reset_boundaries(load_timeline(repo), palette.get("reset_after_hours", 24))
    pens = Pens(repo)
    if a.all:
        files = sorted(f for f in (repo / "raw").rglob("*.jsonl") if f.name != "mode.jsonl")
        if not files:
            raise SystemExit(f"no raw pages under {repo / 'raw'}")
        for f in files:
            render_file(f, repo, books, None, a.png, a.crop, a.nib, palette, modes, boundaries, pens)
    elif a.raw:
        render_file(pathlib.Path(a.raw).expanduser(), repo, books,
                    pathlib.Path(a.out).expanduser() if a.out else None, a.png, a.crop, a.nib,
                    palette, modes, boundaries, pens)
    else:
        ap.error("give a raw file or --all")


if __name__ == "__main__":
    main()
