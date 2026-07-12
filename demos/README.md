# Demos

Standalone example programs built on the `fullaz` library. Each demo is its own
module + executable + test suite, wired into the top-level `build.zig`.

| Demo | What it is | Run | Test |
|------|------------|-----|------|
| [`fsx/`](fsx) | A persistent filesystem in a single file — B+ tree directories, a weighted chained-store for file content, free-list page reclamation. | `zig build run-fs -- <image> [--format] [cmd]` | `zig build test-fs` |
| [`galaxy/`](galaxy) | A starfield explorer on the paged R\*-tree — the viewport is a window query, movement reveals deterministically-generated stars, the whole galaxy persists to one file. | `zig build run-galaxy -- <image> [--format] [--seed N] [cmd]` | `zig build test-galaxy` |

See the top-level [README](../README.md) for full write-ups and example output.
