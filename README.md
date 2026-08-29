# fullaz

**Demos built on it:** see [`demos/README.md`](demos/README.md).

**fullaz** is a low-level storage and indexing library written in Zig.

This project is an **educational Zig-native reimplementation** of the ideas and architecture behind the C++ project **fulla**.
Its primary goal is learning and experimentation with page-based storage and indexing structures, not production use.

The code favors explicitness, clarity, and correctness over completeness or performance tuning.

---

## Project goals

- Learn Zig by building a non-trivial systems-level project
- Explore page-oriented storage design
- Implement B+ tree and related indexing structures step by step
- Experiment with ordered, weighted, spatial, and page-based indexes
- Make ownership, borrowing, and lifetimes explicit
- Experiment with model-based design using Zig's compile-time features

---

## What this project is

- A **learning project**
- A playground for storage engine internals
- A reference implementation for educational purposes
- A place to experiment with B+ tree design

## What this project is NOT

- A production-ready database
- A high-performance storage engine
- A complete DBMS
- A concurrency-safe system (for now)

---

## Design principles

### Page-based architecture

All data structures operate on fixed-size pages provided by a pager or memory model.
There are no implicit allocations or hidden memory ownership rules.

### Explicit ownership and borrowing

APIs distinguish between:

- input types
- output types
- borrowed views

This makes data lifetimes and validity rules visible in the code.

### Model-based design

Core components (memory, pages, trees) are parameterized by user-supplied models.
This allows experimenting with different implementations without runtime overhead.

### Simplicity first

The code is written to be read, understood, and modified.
If something can be made simpler for learning purposes, it probably will be.

---

## Planned components

- In-memory pager (for testing and learning)
- Page layout (headers, slots, payload area)
- B+ tree and weighted B+ tree indexes
- Skip list and weighted skip list
- Radix tables and sparse paged mappings
- Long-value and chained storage experiments
- Spatial indexing experiments
- Minimal tests and examples

---

## Planned Features/Structures

### Roadmap Snapshot

#### Page layout & primitives

- [X]  **Variadic slots**
- [X]  **Fixed-size slots**

#### Ordered index structures

- [X]  **B+ tree (in-memory / paged)** implemented
- [X]  **Weighted B+ tree (in-memory / paged)**
- [X]  **Skip list**
- [ ]  **Weighted skip list**
- [ ]  **B+ tree over spatial keys** (Morton/Z-order or similar)

#### Sparse / virtual addressing structures

- [X]  **Radix tables**
- [X]  **Virtual page mapping** (low-level `VID -> PID` Memory/Paged VPM)
- [ ]  **Snapshot-aware radix mapping**

#### Sequence / weighted structures

- [X]  **Weighted B+ tree**
- [ ]  **Weighted skip list**
- [ ]  **Rope-like chunked sequence**
- [ ]  **Piece-table-like storage experiment**

#### Spatial index structures

- [X]  **R-tree**
- [X]  **R*-tree split/reinsert experiments**
- [ ]  **KD-tree**
- [X]  **Quadtree** (dimension-parametric `Orthtree` with in-memory and paged
  models; paged nodes are fixed slots selected through a persistent FSM, while
  the in-memory 2D model powers the gravity demo)
- [X]  **Octree** (the same `Orthtree` at three dimensions over the paged model;
  the cloud demo is the first user, and the split policy is configurable through
  `max_tree_depth` and `min_cell_extent`)
- [ ]  **Grid / hash-grid coarse spatial partitioning**

#### Point-cloud / spatial storage experiments

- [X]  **Chunked point storage** (each octree node owns a chain of entry pages)
- [X]  **Bounding-box metadata per chunk** (node bounds plus a per-node
  aggregate trait: how many points its subtree holds and where their centroid is)
- [X]  **LOD-friendly chunk hierarchy** (a node smaller on screen than the
  detail threshold is drawn as one splat standing for its whole subtree)
- [ ]  **Spatial query prototype** (`bbox -> chunk refs`)

#### Storage backends

- [ ]  **Long-value store** partially implemented
- [X]  **Chained store** (linked chunk pages + optional weighted offset index)
- [X]  **Page cache**
- [X]  **File-backed block device** (`FileBlock`)
- [X]  **Free-space map + page reclamation** (`fsm`, free list)
- [ ]  **Object/chunk store abstraction**
- [X]  **Dirty-page tracking**

#### Durability & Recovery

- [X]  **Write-Ahead Log (WAL)** (partially; simple redo-only)
- [ ]  **Page diffs / delta logging** planned
- [X]  **Backing-replacement copy-on-write** (experimental; not snapshots/MVCC)
- [ ]  **Snapshot-aware copy-on-write / MVCC**
- [ ]  **Generation-based page tracking**

## Status

🚧 Work in progress
The project is developed incrementally, step by step.

---

## fsx: a filesystem in a single file

**fsx** is a small demo built *on top of* fullaz: a complete, persistent
filesystem that lives entirely inside one host file. It exists to exercise the
storage engine end to end: the page cache, free-space reclamation, a paged B+
tree per directory, and a weighted-index chained store for file content while
keeping `fullaz` itself free of any filesystem-specific knowledge.

- **One image, real persistence.** `fsx <image>` opens (or `--format` creates) a
  4 KiB-page image on disk. Every mutation is flushed, so each command in the
  session below is a *separate process* reading and writing the same file.
- **Nested paths.** Each directory is a paged B+ tree mapping a name (up to 64
  bytes) to an inline value; a file keeps its content in a chained store indexed
  by a weighted B+ tree for O(log n) offset seeks.
- **Self-cleaning.** `rm` / `rmdir` return every page they release to a free
  list, so deleting reclaims space *inside* the image rather than growing it.
- **Two ways to drive it:** a one-shot mode (`fsx <image> [command…]`, shown
  below) and an interactive [zigline](https://github.com/newenclave/zigline)
  REPL with history and line editing (`fsx <image>` with no command).

### Building & running

```sh
zig build                                    # builds the fullaz library + the fsx exe
zig build run-fs -- <image> [--format] [command args...]
zig build test-fs                            # runs the fsx test suite
```

Or call the built binary directly (`zig-out/bin/fsx`). The commands:

```
commands: pwd cd ls tree mkdir rmdir touch rm write cat stat help quit
```

### Example session (real output)

Build a small tree in a fresh image: `--format` creates it, and a command may
follow the flag in the same invocation:

```
$ fsx demo.img --format mkdir /docs
$ fsx demo.img mkdir /docs/notes
$ fsx demo.img touch /docs/readme.txt
$ fsx demo.img write /docs/readme.txt "hello from fsx"
$ fsx demo.img touch /docs/notes/todo.txt
$ fsx demo.img write /docs/notes/todo.txt "write the readme"
```

Read it back: every command here is a brand-new process reading straight from
the image on disk:

```
$ fsx demo.img cat /docs/readme.txt
hello from fsx
$ fsx demo.img stat /docs/readme.txt
file size=14
$ fsx demo.img ls /docs
notes/
readme.txt
$ fsx demo.img tree /
/
  docs/
    notes/
      todo.txt
    readme.txt
```

Remove entries: the pages they held are reclaimed within the image:

```
$ fsx demo.img rm /docs/notes/todo.txt
$ fsx demo.img rmdir /docs/notes
$ fsx demo.img tree /
/
  docs/
    readme.txt
```

Errors are reported, never fatal:

```
$ fsx demo.img cat /docs/missing
error: NotFound
```

---

## galaxy: an R-tree you can fly through

**galaxy** is a second demo built *on top of* fullaz: a ship exploring an
endless 2-D starfield backed by the paged **R\*-tree**. It turns the spatial
index into something you can *see* "looking around" is a window query, moving
reveals new space, and the whole galaxy lives in one file so you can pick up
exploring where you left off.

- **The viewport is a query.** `look` is an R-tree `search(box)` over the 16×16
  window around you; the stars it returns are drawn to an ASCII map.
- **Endless, deterministic space.** The world is tiled into cells; a cell's
  stars are a pure function of its coordinates and the world seed, so `--seed N`
  fully determines the galaxy (including where you spawn). Cells are populated
  the first time they scroll into view and never regenerated: the R-tree file
  *is* the saved galaxy, no side bookkeeping.
- **Real coordinates.** Positions are `f64` "light-years", so you appear
  somewhere like `(850920.8, 380720.3)` in a vast space. This exercises
  fullaz's float on-page encoding (`PackedFloat` / `PackedNumber`).
- **One image, real persistence.** Like fsx, each command below is a *separate
  process* reading and writing the same file (flush + `fsync` on save/quit).
- **Two ways to drive it:** one-shot commands (shown below) and an interactive
  [zigline](https://github.com/newenclave/zigline) REPL: `w`/`a`/`s`/`d` to fly.

### Building & running

```sh
zig build                                    # builds the fullaz library + the galaxy exe
zig build run-galaxy -- <image> [--format] [--seed N] [command]
zig build test-galaxy                        # runs the galaxy test suite
```

Or call the built binary directly (`zig-out/bin/galaxy`). The commands:

```
commands: look (l)   w a s d (fly N/W/S/E; also north south east west)   where   save   help   quit
```

### Example session (real output)

Appear in a fresh galaxy and look around. `--format` creates the image and
`--seed` makes the whole galaxy reproducible; `@` is your ship, dead-center:

```
$ galaxy world.gx --format --seed 42 look
                                +
*       * *+         **         ++         ·
                     ✦                        *
 ✦+ +                                       ✦             *
        ✦            ·
         *          *✦*                             ·
                     +
                        ✦                             ·· +
                           ··  +  ·
                               ✦   +                    +
                              @                        +
+                               + *                +    ✦
               *            · +    ✦                ✦·✦+
             *✦
      · +                                ✦    ·             *
                               ·+        ·  *·
             + ·✦               ·   ✦              *✦
           ·                       +           ·*    *  +
                                                *      ✦
  * +     **    ·  +                    +
         +·  ·       ✦               *·
at (850920.8, 380720.3)  view 16x16  stars in view: 98
```

Fly east: a brand-new process reading the image from disk. New space scrolls
in and its stars are generated on the spot (the map redraws around you):

```
$ galaxy world.gx d
9 new star(s) drift into view
at (850921.8, 380720.3)  view 16x16  stars in view: 103
```

Reopen later and you are right where you left off:

```
$ galaxy world.gx where
at (850921.8, 380720.3)  view 16x16
```

---

## cloud: a point cloud that draws itself at the right detail

**cloud** is the third demo on top of fullaz, and the first user of the paged
**octree**. It holds a 3-D point cloud in one image file and draws it by walking
the tree with the same pruning traversal the gravity demo uses for Barnes-Hut —
except here the per-node aggregate serves the renderer instead of the physics.

- **The aggregate is the level of detail.** Every node carries how many points
  its subtree holds and where their centroid is, maintained by the trait hooks
  (`onInsert`, `onAdopt`, `onGrow`, `onRemove`). A node that covers less of the
  screen than the detail threshold is drawn as a single splat standing for all
  of them; anything bigger is descended into. Zoom out and thousands of points
  collapse into a handful of blobs; zoom in and they resolve again.
- **Every point is accounted for, exactly once.** Aggregated, culled or drawn
  individually — the three counts always add up to the number of entries in the
  tree, which is what the demo's central test asserts at every threshold.
- **One traversal, two front ends.** The terminal renders into a per-cell depth
  buffer, the browser composites additively onto a canvas. Only the final
  rasterisation differs; the projection and the pruning are shared code, and the
  threshold is a fraction of the viewport height so it means the same thing in an
  80x24 grid and a 1200-pixel canvas.
- **All of it in Zig.** The browser gets a flat buffer of already-projected
  splats and stays a rasteriser; there is no 3-D library on the page, and no
  external resource of any kind.
- **One image, real persistence.** The tree, the free-space map and the camera
  live in a single file. Reopening restores the view and does not regenerate or
  regrow anything.

### Building & running

```sh
zig build                                    # builds the fullaz library + the cloud exe
zig build run-cloud -- <image> [--format] [--points N] [--detail PERCENT]
zig build test-cloud                         # runs the cloud test suite
```

With a terminal it is a full-screen viewer: `h`/`l` and `j`/`k` orbit, `+`/`-`
zoom, `[`/`]` change the detail threshold, `i` adds ten thousand points, `w`
writes the image, `q` quits. Without one it builds the image, prints one frame
and exits. Build it for the browser with `zig build wasm-cloud` and serve
`zig-out/web-cloud` over HTTP.

### Example session (real output)

`--format` creates the image and generates the scene: a dozen Gaussian clusters
plus a sparse uniform background, so the octree has something uneven to adapt to.
Denser regions collapse into `•` and `◆`; single points stay `·`:

```
$ cloud world.cld --format --seed 11 --points 60000 --detail 25 --distance 3

                            · ··············· ···
                          ························
                          ························
                          ·······················
                          ········•·········•·•··
                          ········•◆·······•·•···
                          ·····••·•◆•············
                           ····••◆••·············
                           ····•·••••···········
                           ····• ••• ·········
                                    •·······
                                      ····

world.cld: 60000 points, 4524 KiB in 4524 pages (77 B/point), seed 11
6764 splats: 138 aggregates + 6626 points, 209 nodes seen
```

Sixty thousand points became 6764 things to draw, and 138 aggregates account for
53 374 of them. Reopen and nothing is rebuilt — same numbers, same file size:

```
$ cloud world.cld
world.cld: 60000 points, 4524 KiB in 4524 pages (77 B/point), seed 11
6764 splats: 138 aggregates + 6626 points, 209 nodes seen
```

### What the image is made of

The browser build draws a map of the physical pages beside the scene, which
makes the storage layout hard to miss. For the image above:

| pages | role |
|-------|------|
| 1 | superblock: tree root, entry count, free-space root, camera |
| 158 | octree nodes, packed eight to a page through the persistent FSM |
| 4357 | point chunks, one chain per node |
| 8 | the free-space map itself |

A point costs about 34 bytes on the page (24 of bounding box, 8 of payload, a
slot-directory entry). The rest is chunk pages that leaves only partly fill,
plus chains orphaned when a node splits and hands its entries to its children —
`destroyPage` is a no-op here and the model always takes fresh pages, so nothing
recycles them. `block_size` and `max_leaf_entries` are tuned together against
that number: at 1 KiB pages it is 77 bytes per point, at 4 KiB it is 125.

---

## Motivation

This project exists to better understand:

- Zig as a systems programming language
- Database storage internals
- Page-based data structures
- Explicit memory and lifetime management

If you are looking for production-ready software, this is not it.
If you want to learn how things work internally -- welcome 🙂

---
