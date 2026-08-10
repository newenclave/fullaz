# Demos

Standalone example programs built on the `fullaz` library. Each demo is its own
module + executable + test suite, wired into the top-level `build.zig`.

| Demo | What it is | Run | Test |
|------|------------|-----|------|
| [`fsx/`](fsx) | A persistent filesystem in a single file — B+ tree directories, a weighted chained-store for file content, free-list page reclamation. | `zig build run-fs -- <image> [--format] [cmd]` | `zig build test-fs` |
| [`galaxy/`](galaxy) | A starfield explorer on the paged R\*-tree — the viewport is a window query, movement reveals deterministically-generated stars, the whole galaxy persists to one file. | `zig build run-galaxy -- <image> [--format] [--seed N] [cmd]` | `zig build test-galaxy` |
| [`gravity/`](gravity) | An interactive Barnes-Hut galaxy simulation using the in-memory 2D orthtree and per-node mass aggregates. | `zig build run-gravity -- [--bodies N] [--theta X] [--dt X] [--seed N] [--central-mass X]` | `zig build test-gravity` |
| [`cloud/`](cloud) | A 3-D point-cloud viewer on the paged **octree** — per-node aggregates drive level of detail, and the whole cloud lives in one image file. | `zig build run-cloud -- <image> [--format] [--points N] [--detail PERCENT]` | `zig build test-cloud` |

`demos/common/` is not a demo: it holds the terminal plumbing (raw-mode input,
ANSI output, console size) shared by `gravity` and `cloud`. `zig build test-common`
covers it.

Build the fsx browser explorer with `zig build wasm-fsx`. It installs `fsx.wasm`
and `index.html` in `zig-out/web-fsx`; serve that directory over HTTP. The browser
keeps its image in IndexedDB and supports `.fsx` import/export.
Create a populated image for it with `python3 fsx/make_demo_image.py <fsx> demo.fsx`.

The gravity demo requires an interactive terminal. Press `Space` to run or pause,
`n` to advance one step while paused, `g` to enter a number of steps to jump, and
`q` to quit.

Build the browser version with `zig build wasm-gravity`; it installs
`gravity.wasm` and `index.html` in `zig-out/web-gravity`. Serve that directory
over HTTP, for example with `python -m http.server --directory zig-out/web-gravity`.

The cloud demo runs either way. With a terminal it is a full-screen viewer:
`h`/`l` and `j`/`k` orbit, `+`/`-` zoom, `[`/`]` change the detail threshold,
`i` adds ten thousand points, `w` writes the image, `q` quits. Without one it
builds the image, prints a single frame as plain text and exits, which makes it
usable from a script. Build the browser version with `zig build wasm-cloud` and
serve `zig-out/web-cloud`; it keeps its image in IndexedDB, supports `.cld`
download and upload, and draws a map of the physical pages next to the scene.

See the top-level [README](../README.md) for full write-ups and example output.
