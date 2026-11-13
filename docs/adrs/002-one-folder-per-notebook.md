---
id: 002
title: Each copy of a notebook is one folder, named by an id we generate
status: accepted
tags: [storage, naming, ncode]
summary: A stroke is filed under the surface identity its client reported; each physical copy of a notebook gets one folder with a generated id, holding its record, its captured pages and its readable files; a setting has no surface, so all settings go to one file in time order.
---

# ADR-002: Each copy of a notebook is one folder, named by an id we generate

**Date:** 2026-09-14
**Status:** Accepted
**Owner:** @matoushavlena

## Context

A stroke needs a surface identity. That is the sheet or canvas a mark was made on. The pen gives one for every stroke, and its form is called an Ncode address. It has four parts, written `s{section}/o{owner}/b{book}/p{page}`.

- **Section** is the top division of the Ncode space. It sets how many bits each of the other parts gets. All our paper is in section 3.
- **Owner** is the company that made the paper. It is not the maker of the pen.
- **Book** is the product, not the copy. Section 3 gives 13 bits to this part. That is 8192 books for each owner.
- **Page** is the sheet inside the product. It is not the number printed on the sheet.

Three books are in use today:

- `s3/o27/b450` is the A4 scratchpad. Owner 27 is NeoLAB's own paper.
- `s3/o1012/b3017` is the LAMY notebook. Owner 1012 is LAMY paper.
- `s3/o1013/b1` is the LAMY paper controller.

What owner 1013 means is not known. The controller ships inside the LAMY notebook, but it does not carry the notebook's owner code. Owner 1013 also holds book 1116, which is Grida, a NeoLAB product. So 1013 is not LAMY alone. It is also not NeoLAB's own paper code, because that code is 27. Two readings fit the evidence. It is a shared code for controllers, or it is a code that the two companies use together. The Paperhub API would answer this, and we have no credentials for it.

Because a book code names a product, two A4 pads of the same kind carry the same surface identity. Their first sheets collide.

A surface identity exists only because the pen read the pattern printed on a sheet. Anything that happens away from paper therefore has none. A person picks an ink colour in the app and the pen takes no part. There is no surface to file that choice under.

## Decision

**A stroke is filed under its surface identity.** Only the client that sensed the surface can give one. We take the client's own and use nothing else. The format does not depend on Ncode. A client that senses another kind of surface brings its own surface identity, and the same format holds its strokes.

**The root is `~/OpenSmartPen`, where a person can see it.** The data stays outside the app, so you can delete the app and install it again.

macOS keeps the data of an application in `~/Library/Application Support`. We do not put these files there. That location is for data that a person must never open: caches, indexes, a database. These files are the opposite. They are the person's own notes, and we made them readable on purpose. A person opens the folder, reads a page, moves a book, and keeps a copy. A location that Finder hides works against all of those.

The root of the home folder is not usual, and we accept that. The other visible location is `~/Documents`. Many Macs sync that folder to iCloud. Then each new line in a record becomes an upload. iCloud can also remove a local file to make space. We add to a record all day, and it must be there when we read it. That is the worst thing to put in such a folder.

A person who disagrees moves the folder. The location is one field in the configuration, `dataPath`. No part of the app calculates a path from the home folder.

**Each copy of a notebook is one folder.** We generate an id the first time we see a new copy. The folder holds everything about that copy: its record, its captured pages, and the readable files made from them.

Inside it, captured and derived stay apart. Everything in `pages/` can be deleted and made again. Nothing in `raw/` can.

```
~/OpenSmartPen/
  mode.jsonl                        every setting, in time order
  pens/pen.json
  books/
    s3-o27-b450-7f3a9c/
      book.json                     surface identity, title, paper size, when this copy began
      raw/     p1.jsonl  p2.jsonl        as the client named them
      pages/   p1.png  p2.png            the same pages, made readable
    s3-o1012-b3017-2b81e4/
      book.json
      raw/     p4.jsonl
      pages/   p4.png
```

**The name of a folder is the surface identity, then the id.** The two are joined by a dash, and any `/` in the surface identity becomes a dash. The pen's `s3/o27/b450` therefore gives `s3-o27-b450-7f3a9c`.

**The id is six characters, from `0` to `9` and `a` to `f`.** We pick it at random and check it against the folders that exist. Six characters give 16 million values, which is far more than a person will ever own.

**The id is opaque and permanent.** Nothing may read meaning out of it. The surface identity in the name is there for a person to read. `book.json` is the only authority.

**One sheet has one name.** A page is named as the client named it, and that name carries through: `raw/p4.jsonl` becomes `pages/p4.png`. You can pair a captured file with its readable one by eye, and no rule stands between them.

The number a person counts to is not thrown away. `book.json` holds which sheet its owner calls page 1, and everything a person reads uses it — the panel, and the front matter of a transcription. It just does not name a file.

**We decide a new copy ourselves, and we never ask.** Two signals beat time alone. A sequence restart: ink appears at the front and marches forward. Ink overlap: new strokes cross old ones, so it cannot be the same sheet.

**A wrong guess is repaired by moving pages.** A page can move from one book folder to another. Nothing inside a file changes, because the content is still exactly what the client reported.

**The title lives in `book.json`.** You can change it at any time and no file moves.

**A setting is filed by time, in one place.** A setting has no surface of its own. All settings go to one file, `mode.jsonl`, and a reader replays them in time order. A setting that came from a tap keeps the identity of the stroke that caused it. The paper is still findable.

## Areas not covered

- Which heuristic decides a new copy, and how sure it must be.
- What repairs a wrong guess, and who starts the repair.
- What starts the work that makes the readable files.
- How we find the page dimensions and the active areas of a notebook.
- Where a command is filed, and how it is raised.

## Alternatives Considered

- **Name the folder by the surface identity alone** — two copies of one product then share a folder, and their pages overwrite each other.
- **Decide the copy late, from a date in the record** — nothing ever moves, but every reader must apply the boundary. One notebook also cannot be held apart from the rest.
- **Ask the person when a new copy appears** — the app must run without attention. A question at the wrong moment is worse than a guess we can repair.
- **Put the data in `~/Library/Application Support`** — the macOS convention, and the right one for data a person must never open. These are the person's notes, which is the opposite kind of data.
- **Put the data in `~/Documents`** — the usual place for documents, and the usual place that syncs to iCloud. An append-only record uploaded on every line, and evicted when the disk fills, is a record we cannot trust.
- **Put the title in the folder name** — a rename would then move every file and break every link into it.
- **Number a readable file as a person counts pages** — `raw/p4.jsonl` then becomes `pages/page-01.png`, and every tool needs the book record before it can pair the two. The offset is still there for a person to read; it does not have to name a file as well.
- **File a setting under the page of the tap that caused it** — a click in the app has no page, so many settings would have no home.

## Consequences

- **Easier:** one folder holds one notebook completely. You can move it, copy it, encrypt it or delete it on its own. That is not possible when pages are keyed by product.
- **Easier:** to make every readable file again, delete one folder. Nothing captured sits beside the files you delete.
- **Easier:** a rename is one field in one file.
- **Harder:** the app must guess whether a copy is new. Two notebooks of the same product, in use at the same time, is the case it will get wrong.
- **Harder:** the surface identity alone no longer finds a page. Something must read the book records to learn which folder holds it.
- **Harder:** a repair moves files, so a tool must exist to do it. Until it does, a wrong guess is fixed by hand.
- **Harder:** a readable file carries the pen's page number, which is not the number printed on the sheet. The LAMY notebook starts at `p4.png` and has no `p1`.
- **Harder:** a folder in the root of the home folder is not what a Mac user expects. We accept one strange folder, which a person learns one time, instead of a location that works against reading the files every day.
- **Committed-to:** the generated id as opaque and permanent, a page as movable between book folders, and one file for every setting.
