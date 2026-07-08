# fullaz

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
- [ ]  **Virtual page table** (`vpid -> pid` mapping)
- [ ]  **Snapshot-aware radix mapping**

#### Sequence / weighted structures

- [X]  **Weighted B+ tree**
- [ ]  **Weighted skip list**
- [ ]  **Rope-like chunked sequence**
- [ ]  **Piece-table-like storage experiment**

#### Spatial index structures

- [ ]  **R-tree**
- [ ]  **R*-tree split/reinsert experiments**
- [ ]  **KD-tree**
- [ ]  **Quadtree**
- [ ]  **Octree**
- [ ]  **Grid / hash-grid coarse spatial partitioning**

#### Point-cloud / spatial storage experiments

- [ ]  **Chunked point storage**
- [ ]  **Bounding-box metadata per chunk**
- [ ]  **LOD-friendly chunk hierarchy**
- [ ]  **Spatial query prototype** (`bbox -> chunk refs`)

#### Storage backends

- [ ]  **Long-value store** partially implemented
- [X]  **Chained store** (linked chunk pages + optional weighted offset index)
- [X]  **Page cache**
- [X]  **File-backed block device** (`FileBlock`)
- [X]  **Free-space map + page reclamation** (`fsm`, free list)
- [ ]  **Object/chunk store abstraction**
- [ ]  **Dirty-page tracking**

#### Durability & Recovery

- [X]  **Write-Ahead Log (WAL)** (partially; simple redo-only)
- [ ]  **Page diffs / delta logging** planned
- [ ]  **Snapshot / copy-on-write experiments**
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

## Motivation

This project exists to better understand:

- Zig as a systems programming language
- Database storage internals
- Page-based data structures
- Explicit memory and lifetime management

If you are looking for production-ready software, this is not it.
If you want to learn how things work internally -- welcome 🙂

---
