#!/usr/bin/env python3
"""Populate a dispatch image with deterministic work orders around the globe.

The dispatch CLI accepts one command per process, so this script deliberately
uses a single writer and waits for every command to commit before continuing.
"""

from __future__ import annotations

import argparse
import math
import random
import shlex
import subprocess
import sys
from pathlib import Path


STATUSES = ("open", "open", "open", "assigned")
PRIORITIES = ("critical", "high", "medium", "low")
ASSETS = (
    "harbor pump",
    "rail relay",
    "river sensor",
    "school meter",
    "wind station",
    "water valve",
    "substation cabinet",
    "traffic controller",
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("image", type=Path, help="dispatch image path")
    result.add_argument("count", type=int, help="number of work orders to add")
    result.add_argument(
        "--dispatch",
        type=Path,
        default=Path("zig-out/bin/dispatch"),
        help="dispatch CLI executable (default: zig-out/bin/dispatch)",
    )
    result.add_argument("--seed", type=int, default=20260822, help="deterministic random seed")
    result.add_argument(
        "--format",
        action="store_true",
        help="format a fresh image before adding the first order",
    )
    result.add_argument("--dry-run", action="store_true", help="print commands without running them")
    return result


def global_point(rng: random.Random) -> tuple[float, float]:
    """Draw uniformly over the sphere rather than clustering at the poles."""
    latitude = math.degrees(math.asin(rng.uniform(-1.0, 1.0)))
    longitude = rng.uniform(-180.0, 180.0)
    return latitude, longitude


def command_for(args: argparse.Namespace, index: int, rng: random.Random) -> list[str]:
    latitude, longitude = global_point(rng)
    radius = rng.uniform(0.02, 0.35)
    value = "|".join((rng.choice(STATUSES), rng.choice(PRIORITIES), rng.choice(ASSETS)))
    command = [str(args.dispatch), str(args.image)]
    if args.format and index == 0:
        command.append("--format")
    command.extend(
        (
            "add",
            f"{index + 1:08d}",
            f"{latitude:.6f}",
            f"{longitude:.6f}",
            f"{radius:.4f}",
            value,
        )
    )
    return command


def main() -> int:
    args = parser().parse_args()
    if args.count < 1 or args.count > 99_999_999:
        parser().error("count must be between 1 and 99,999,999")
    if not args.dry_run and not args.dispatch.is_file():
        parser().error(f"dispatch executable not found: {args.dispatch}")
    if args.format and args.image.exists():
        parser().error(f"--format refuses to overwrite an existing image: {args.image}")

    rng = random.Random(args.seed)
    for index in range(args.count):
        command = command_for(args, index, rng)
        if args.dry_run:
            print(shlex.join(command))
            continue
        completed = subprocess.run(command, check=False, text=True, capture_output=True)
        if completed.returncode != 0:
            sys.stderr.write(completed.stdout)
            sys.stderr.write(completed.stderr)
            print(f"failed after {index} committed order(s)", file=sys.stderr)
            return completed.returncode
        if completed.stdout:
            print(completed.stdout, end="")

    if args.dry_run:
        return 0
    print(f"generated {args.count} global work orders in {args.image}")
    return 0



if __name__ == "__main__":
    raise SystemExit(main())
