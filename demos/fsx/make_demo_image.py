#!/usr/bin/env python3
"""Create a deterministic, browseable fsx image for the native and WASM demos."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys


DIRECTORIES = (
    "/docs",
    "/docs/guides",
    "/docs/design",
    "/projects",
    "/projects/nebula",
    "/notes",
    "/archive",
)

FILES = {
    "/README.txt": "Welcome to the fsx demo image. Explore the directories, then edit a file in the browser demo.",
    "/docs/welcome.txt": "Documentation lives in a paged B+ tree. Each directory entry is stored in a leaf page.",
    "/docs/guides/getting-started.txt": "1. Open a file. 2. Change its text. 3. Save. 4. Watch the physical page map update.",
    "/docs/design/storage-map.txt": "Yellow pages are directories. Blue pages contain file chunks. Purple pages are file indexes.",
    "/projects/nebula/ideas.txt": "Nebula project notes:\n- build a star catalog\n- preserve page locality\n- make the inspector useful",
    "/notes/today.txt": "Try creating a directory, adding a file, and replacing this text from the editor.",
    "/archive/README.txt": "This directory is intentionally quiet. Delete it after removing this file to exercise reclamation.",
}


def run(fsx: Path, image: Path, *command: str, format_image: bool = False) -> None:
    args = [str(fsx), str(image)]
    if format_image:
        args.append("--format")
    args.extend(command)
    subprocess.run(args, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fsx", type=Path, help="path to fsx executable (fsx or fsx.exe)")
    parser.add_argument("image", type=Path, help="output .fsx image path")
    parser.add_argument("--force", action="store_true", help="replace an existing image and its WAL sidecar")
    args = parser.parse_args()

    if not args.fsx.is_file():
        parser.error(f"fsx executable does not exist: {args.fsx}")
    if args.image.exists() and not args.force:
        parser.error(f"image already exists: {args.image} (pass --force to replace it)")

    if args.force:
        args.image.unlink(missing_ok=True)
        args.image.with_name(args.image.name + ".wal").unlink(missing_ok=True)
    args.image.parent.mkdir(parents=True, exist_ok=True)

    first, *remaining = DIRECTORIES
    run(args.fsx, args.image, "mkdir", first, format_image=True)
    for directory in remaining:
        run(args.fsx, args.image, "mkdir", directory)
    for path, content in FILES.items():
        run(args.fsx, args.image, "touch", path)
        run(args.fsx, args.image, "write", path, content)

    print(f"created {args.image}")
    run(args.fsx, args.image, "tree", "/")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"fsx command failed with exit code {error.returncode}", file=sys.stderr)
        raise SystemExit(error.returncode)
