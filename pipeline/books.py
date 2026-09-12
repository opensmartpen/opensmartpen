"""Notebooks: the bridge between what the pen says and what a person calls things.

The pen identifies paper by Ncode: section, owner, book, page. That is precise, permanent
and unreadable — `s3/o27/b450/p12` tells you nothing about which notebook is on your desk.
It stays the key for raw capture, because it is the only identifier the hardware knows and
it must not depend on anything a person might rename later.

Everything a person reads goes through a book record instead, one JSON file per notebook in
`books/`, named by the slug it gives:

    books/a4-pad.json
    {
      "id": "s3/o27/b450",
      "title": "Ncode A4 pad",
      "width_mm": 210.0,
      "height_mm": 297.0,
      "first_page": 1
    }

A book code identifies a *product*, not a physical copy: two identical A4 pads report the
same section, owner and book, so their page 1s share an address. A record may therefore carry
`instances`, each a slug and the moment writing in that copy began:

    "instances": [{"slug": "a4-pad", "startedAt": 0},
                  {"slug": "a4-pad-2", "startedAt": 1757671234567}]

A stroke belongs to the last instance that began at or before it. One raw page file can hold
strokes from both copies, so rendering splits it and each copy gets its own directory under
`pages/`. Without the array there is one copy and nothing changes.

`first_page` is what the pen calls the notebook's first sheet. Ncode page numbers do not
start at one: the LAMY pad's first sheet reports as page 4. Subtracting it gives the page
number a human would count to.
"""

from __future__ import annotations

import json
import pathlib
import re


class Book:
    def __init__(self, slug: str, data: dict):
        self.slug = slug
        self.id: str = data["id"]
        self.title: str = data.get("title", slug)
        self.width_mm: float | None = data.get("width_mm")
        self.height_mm: float | None = data.get("height_mm")
        self.first_page: int = int(data.get("first_page", 1))
        self.source: str = data.get("source", "recorded")
        self.instances: list[tuple[int, str]] = sorted(
            (int(i["startedAt"]), i["slug"]) for i in data.get("instances", []) if i.get("slug"))

    @property
    def has_geometry(self) -> bool:
        return bool(self.width_mm and self.height_mm)

    def human_page(self, ncode_page: int) -> int:
        """Page number as a person would count it, 1 for the first sheet."""
        return ncode_page - self.first_page + 1

    def ncode_page(self, human_page: int) -> int:
        return human_page + self.first_page - 1

    def page_stem(self, ncode_page: int) -> str:
        return f"page-{self.human_page(ncode_page):02d}"

    def instance_at(self, ms: int) -> str:
        """Which physical copy of this notebook was being written in at that moment."""
        slug = self.slug
        for started, instance in self.instances:
            if started <= ms:
                slug = instance
        return slug


class Books:
    """Every known notebook, looked up by either name."""

    def __init__(self, repo: pathlib.Path):
        self.repo = repo
        self.by_slug: dict[str, Book] = {}
        self.by_id: dict[str, Book] = {}
        for f in sorted((repo / "books").glob("*.json")):
            b = Book(f.stem, json.loads(f.read_text()))
            self.by_slug[b.slug] = b
            self.by_id[b.id] = b

    def for_id(self, book_id: str) -> Book | None:
        return self.by_id.get(book_id)

    def for_slug(self, slug: str) -> Book | None:
        return self.by_slug.get(slug)


RAW_RE = re.compile(r"(s\d+)/(o\d+)/(b\d+)/p(\d+)\.jsonl$")


def parse_raw_path(path: pathlib.Path) -> tuple[str, int]:
    """('s3/o27/b450', 12) from a raw page file path."""
    m = RAW_RE.search(str(path))
    if not m:
        raise ValueError(f"not a raw page file: {path}")
    return "/".join(m.group(1, 2, 3)), int(m.group(4))


def raw_path(repo: pathlib.Path, book_id: str, ncode_page: int) -> pathlib.Path:
    return repo / "raw" / book_id / f"p{ncode_page}.jsonl"


def page_dir(repo: pathlib.Path, book: Book | None, book_id: str) -> pathlib.Path:
    """Where the readable files for a page go. Falls back to the Ncode id for an
    unknown notebook, so nothing is lost before someone gets round to naming it."""
    return repo / "pages" / (book.slug if book else book_id)


def page_stem(book: Book | None, ncode_page: int) -> str:
    return book.page_stem(ncode_page) if book else f"p{ncode_page}"


class Pens:
    """Pens by MAC address, from `pens/*.json` in the notes repo.

    Every stroke records which pen made it, and a pen carries its own default ink and width.
    Writing that resumes after a long silence starts again at those defaults, so the renderer
    has to know them; without a record the fallbacks are black at the default width.

    The MAC is matched loosely — case folded, separators removed — because a file written by
    hand should not have to match the pen's own formatting exactly.
    """

    def __init__(self, repo: pathlib.Path):
        self.by_mac: dict[str, dict] = {}
        for f in sorted((repo / "pens").glob("*.json")):
            data = json.loads(f.read_text())
            mac = data.get("mac") or data.get("id") or data.get("penMac")
            if mac:
                self.by_mac[self.normalise(mac)] = data

    @staticmethod
    def normalise(mac: str) -> str:
        return re.sub(r"[^0-9a-f]", "", mac.lower())

    def defaults(self, mac: str | None) -> tuple[str, str]:
        """(ink, width) this pen starts from."""
        data = self.by_mac.get(self.normalise(mac or ""), {})
        return data.get("ink", "black"), data.get("width", "default")
