"""Notebooks: the bridge between what the pen says and what a person calls things.

The pen identifies paper by Ncode: section, owner, book, page. That is precise, permanent
and unreadable — `s3/o27/b450/p12` tells you nothing about which notebook is on your desk.
It is also the identity of a *product*, not of a copy: two identical A4 pads report the same
section, owner and book, so their page 1s share an address.

So each physical copy gets a folder of its own, named by the surface identity the client
reported and an id the app generated (ADR-002):

    ~/Brainio/pen/
      mode.jsonl
      pens/pen.json
      books/
        s3-o27-b450-7f3a9c/
          book.json          {"surface": "s3/o27/b450", "title": "Ncode A4 pad",
                              "width_mm": 210.0, "height_mm": 297.0, "first_page": 1,
                              "started_at": 0, "decided_by": null}
          raw/     p1.jsonl           as the client named the page
          pages/   p1.svg p1.md        the same page, made readable

The id is opaque. Nothing may read meaning out of it; `book.json` is the only authority on
what a copy is called and where its page numbers start. That is what lets a title change
without a single file moving.

`first_page` is what the pen calls the notebook's first sheet. Ncode page numbers do not
start at one: the LAMY pad's first sheet reports as page 4. Subtracting it gives the page
number a human would count to.
"""

from __future__ import annotations

import json
import pathlib
import re


class Book:
    """One physical copy of a notebook, from its own `book.json`."""

    def __init__(self, folder: str, data: dict):
        self.folder = folder
        # `id` is what the surface identity was called before ADR-002. Read, never written.
        self.surface: str = data.get("surface") or data["id"]
        self.title: str = data.get("title", folder)
        self.width_mm: float | None = data.get("width_mm")
        self.height_mm: float | None = data.get("height_mm")
        self.first_page: int = int(data.get("first_page", 1))
        self.source: str = data.get("source", "recorded")
        # When this copy began, and which signal decided it was a new one. Zero and None for the
        # first copy of a product, which was not decided — it was simply the first.
        self.started_at: int = int(data.get("started_at", 0))
        self.decided_by: str | None = data.get("decided_by")

    @property
    def has_geometry(self) -> bool:
        return bool(self.width_mm and self.height_mm)

    def human_page(self, ncode_page: int) -> int:
        """Page number as a person would count it, 1 for the first sheet."""
        return ncode_page - self.first_page + 1

    def ncode_page(self, human_page: int) -> int:
        return human_page + self.first_page - 1

    def page_stem(self, ncode_page: int) -> str:
        return f"p{ncode_page}"


class Books:
    """Every copy of every notebook, looked up by folder or by surface identity."""

    def __init__(self, root: pathlib.Path):
        self.root = root
        self.by_folder: dict[str, Book] = {}
        self.by_surface: dict[str, list[Book]] = {}
        for f in sorted(root.glob("books/*/book.json")):
            try:
                b = Book(f.parent.name, json.loads(f.read_text()))
            except (ValueError, KeyError):
                continue        # a folder somebody made by hand is not a book
            self.by_folder[b.folder] = b
            self.by_surface.setdefault(b.surface, []).append(b)
        # The copy in use is the one that began last. This order answers that question, so it is
        # not a presentation choice.
        for copies in self.by_surface.values():
            copies.sort(key=lambda b: (b.started_at, b.folder))

    def for_folder(self, folder: str) -> Book | None:
        return self.by_folder.get(folder)

    def current(self, surface: str) -> Book | None:
        """The copy being written in now."""
        copies = self.by_surface.get(surface)
        return copies[-1] if copies else None

    def copies(self, surface: str) -> list[Book]:
        return list(self.by_surface.get(surface, []))

    def all(self) -> list[Book]:
        return list(self.by_folder.values())


RAW_RE = re.compile(r"books/([^/]+)/raw/p(\d+)\.jsonl$")


def parse_raw_path(path: pathlib.Path) -> tuple[str, int]:
    """('s3-o27-b450-7f3a9c', 12) from a captured page file path."""
    m = RAW_RE.search(str(path))
    if not m:
        raise ValueError(f"not a captured page file: {path}")
    return m.group(1), int(m.group(2))


def surface_of(folder: str) -> str:
    """The surface identity a folder name carries, for a folder with no readable record."""
    parts = folder.rsplit("-", 1)[0].split("-")
    return "/".join(parts) if len(parts) == 3 else folder


def raw_path(root: pathlib.Path, folder: str, ncode_page: int) -> pathlib.Path:
    return root / "books" / folder / "raw" / f"p{ncode_page}.jsonl"


def raw_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Every captured page in every copy."""
    return sorted(root.glob("books/*/raw/p*.jsonl"))


def page_dir(root: pathlib.Path, folder: str) -> pathlib.Path:
    """Where the readable files for a copy go. Beside its captured files but not among them:
    everything here can be deleted and made again, and nothing in `raw/` can."""
    return root / "books" / folder / "pages"


def page_stem(book: Book | None, ncode_page: int) -> str:
    return book.page_stem(ncode_page) if book else f"p{ncode_page}"


class Pens:
    """Pens by MAC address, from `pens/*.json` at the root of the notes.

    Every stroke records which pen made it, and a pen carries its own default ink and width.
    Writing that resumes after a long silence starts again at those defaults, so the renderer
    has to know them; without a record the fallbacks are black at the default width.

    The MAC is matched case-folded with separators stripped, matching PenRecord.normalise on the
    app side: the SDK reports a punctuated address and raw stores a bare one, and they have to
    compare one way only. If the two normalisers ever disagree the miss is silent and looks like
    black ink, which is exactly the failure this whole design avoids elsewhere.
    """

    def __init__(self, root: pathlib.Path):
        self.by_mac: dict[str, dict] = {}
        for f in sorted((root / "pens").glob("*.json")):
            data = json.loads(f.read_text())
            mac = data.get("mac")
            if mac:
                self.by_mac[self.normalise(mac)] = data

    @staticmethod
    def normalise(mac: str) -> str:
        return re.sub(r"[^0-9a-f]", "", mac.lower())

    def defaults(self, mac: str | None) -> tuple[str, str]:
        """(ink, width) this pen starts from."""
        data = self.by_mac.get(self.normalise(mac or ""), {})
        return data.get("ink", "black"), data.get("width", "default")
