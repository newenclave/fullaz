# Demos

Standalone example programs built on the `fullaz` library. Each demo is its own
module + executable + test suite, wired into the top-level `build.zig`.

| Demo | What it is | Run | Test |
|------|------------|-----|------|
| [`fsx/`](fsx) | A persistent filesystem in a single file — B+ tree directories, a weighted chained-store for file content, free-list page reclamation. | `zig build run-fs -- <image> [--format] [cmd]` | `zig build test-fs` |
| [`galaxy/`](galaxy) | A starfield explorer on the paged R\*-tree — the viewport is a window query, movement reveals deterministically-generated stars, the whole galaxy persists to one file. | `zig build run-galaxy -- <image> [--format] [--seed N] [cmd]` | `zig build test-galaxy` |
| [`gravity/`](gravity) | An interactive Barnes-Hut galaxy simulation using the in-memory 2D orthtree and per-node mass aggregates. | `zig build run-gravity -- [--bodies N] [--theta X] [--dt X] [--seed N] [--central-mass X]` | `zig build test-gravity` |

The gravity demo requires an interactive terminal. Press `Space` to run or pause,
`n` to advance one step while paused, `g` to enter a number of steps to jump, and
`q` to quit.

Build the browser version with `zig build wasm-gravity`; it installs
`gravity.wasm` and `index.html` in `zig-out/web-gravity`. Serve that directory
over HTTP, for example with `python -m http.server --directory zig-out/web-gravity`.

See the top-level [README](../README.md) for full write-ups and example output.
