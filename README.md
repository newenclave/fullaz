# fullaz

**fullaz** is a low-level storage and indexing library written in Zig.

This project is an **educational Zig-native reimplementation** of the ideas and architecture behind the C++ project **fulla**.
Its primary goal is learning and experimentation with page-based storage and indexing structures, not production use.

The code favors explicitness, clarity, and correctness over completeness or performance tuning.

---

## Project goals

- Learn Zig by building a non-trivial systems-level project
- Explore page-oriented storage design
- Implement a B+ tree step by step
- Make ownership, borrowing, and lifetimes explicit
- Experiment with model-based design using Zig’s compile-time features

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
- B+ tree (leaf and internal nodes)
- Minimal tests and examples

---

## Planned Features/Structures

### Roadmap Snapshot

#### Page layout & primitives

- [X] **Variadic slots** implemented
- [ ] **Fixed-size slots** planned

#### Index structures

- [X] **B+ tree (in-memory / paged)** implemented
- [ ] **Weighted B+ tree (in-memory / paged)** in development
- [ ] **Radix tables** planned

#### Storage backends

- [ ] **Long-value store** partially implemented
- [ ] **Chained store** in development

#### Durability & Recovery

* [ ] **Write-Ahead Log (WAL)** planned
* [ ] **Page diffs / delta logging** planned



## Status

🚧 Work in progress
The project is developed incrementally, step by step.

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
