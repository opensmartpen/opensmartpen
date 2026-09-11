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
