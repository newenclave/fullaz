#!/usr/bin/env python3
"""Generate game-like planet records as a JSON object for the SSTable demo."""

import argparse
import json
import random
import sys


STARTS = (
    "al", "an", "ar", "bel", "cor", "da", "de", "el", "es", "fal", "gar",
    "hel", "is", "jar", "kal", "lor", "mar", "nar", "or", "pel", "qua", "ren",
    "sar", "tel", "ul", "val", "wen", "xel", "yor", "zan",
)
MIDDLES = (
    "a", "ae", "an", "ar", "e", "el", "en", "er", "ev", "ia", "in", "ir",
    "o", "ol", "on", "or", "u", "ul", "un", "ur", "ys", "za",
)
ENDS = (
    "bar", "dun", "ea", "eron", "eth", "ia", "ion", "is", "or", "ora", "os",
    "oth", "prime", "ra", "ria", "ron", "ta", "ter", "tis", "une", "us", "var",
)
WORLD_TYPES = (
    "basaltic world", "desert world", "ocean world", "temperate terrestrial world",
    "tidally heated moon", "frozen super-Earth", "iron-rich world", "storm planet",
)
ATMOSPHERES = (
    "nitrogen-oxygen", "thin carbon dioxide", "dense methane", "argon-nitrogen",
    "sulfurous", "helium-hydrogen", "oxygen-rich", "trace vapor",
)
RESOURCES = (
    "cobalt and nickel", "rare earth ores", "water ice and ammonia", "lithium brines",
    "titanium deposits", "volatile hydrocarbons", "crystalline silicates", "geothermal salts",
    "platinum-group metals", "deuterium ice",
)
CLIMATES = (
    "calm polar seas", "permanent electrical storms", "dust seasons", "active rift valleys",
    "a planet-wide ice shelf", "equatorial cloud belts", "violent tidal currents", "sparse fungal forests",
)


def planet_name(rng: random.Random) -> str:
    parts = [rng.choice(STARTS), rng.choice(MIDDLES), rng.choice(ENDS)]
    if rng.random() < 0.3:
        parts.insert(2, rng.choice(MIDDLES))
    return "".join(parts).capitalize()


def planet_description(rng: random.Random) -> str:
    coordinates = tuple(rng.uniform(-10_000.0, 10_000.0) for _ in range(3))
    day_hours = rng.uniform(8.0, 72.0)
    gravity = rng.uniform(0.35, 1.85)
    temperature = rng.randint(-145, 58)
    return (
        f"{rng.choice(WORLD_TYPES).capitalize()}. "
        f"Coordinates: ({coordinates[0]:.3f}, {coordinates[1]:.3f}, {coordinates[2]:.3f}) ly. "
        f"Atmosphere: {rng.choice(ATMOSPHERES)}. "
        f"Day length: {day_hours:.1f} standard hours. "
        f"Surface gravity: {gravity:.2f} g. "
        f"Mean temperature: {temperature} C. "
        f"Primary resources: {rng.choice(RESOURCES)}. "
        f"Notable conditions: {rng.choice(CLIMATES)}."
    )


def generate(count: int, seed: int | None) -> dict[str, str]:
    rng = random.Random(seed)
    planets: dict[str, str] = {}
    while len(planets) < count:
        name = planet_name(rng)
        if name in planets:
            continue
        planets[name] = planet_description(rng)
    return dict(sorted(planets.items()))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("count", type=int, help="number of unique planets to generate")
    parser.add_argument("--seed", type=int, help="seed for reproducible output")
    parser.add_argument("--output", type=argparse.FileType("w"), default=sys.stdout)
    args = parser.parse_args()
    if args.count < 1:
        parser.error("count must be positive")

    json.dump(generate(args.count, args.seed), args.output, indent=2)
    args.output.write("\n")
    if args.output is not sys.stdout:
        args.output.close()


if __name__ == "__main__":
    main()
