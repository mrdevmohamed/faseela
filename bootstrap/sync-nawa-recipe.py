#!/usr/bin/env python3
"""Synchronize the fetched Nawa recipe with Bootstrap's independent source lock.

The lock in bootstrap/nawa-source.toml is authoritative for both the stage-2
bootstrap binary and the Nawa package built into the finished system. This
keeps a Bootstrap build from depending on a separately merged faseela-repo
recipe-pin PR.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = ROOT / "bootstrap" / "nawa-source.toml"
DEFAULT_RECIPE = ROOT / "recipes" / "base" / "nawa" / "recipe.toml"


def load_lock(path: Path) -> dict:
    try:
        lock = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise SystemExit(f"sync-nawa-recipe: cannot read {path}: {exc}") from exc

    required = {"schema", "repository", "version", "rel", "commit", "sha256"}
    missing = sorted(required - lock.keys())
    if missing:
        raise SystemExit(f"sync-nawa-recipe: {path} is missing: {', '.join(missing)}")
    if lock["schema"] != 1:
        raise SystemExit(f"sync-nawa-recipe: unsupported lock schema {lock['schema']!r}")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", str(lock["repository"])):
        raise SystemExit("sync-nawa-recipe: repository must be owner/name")
    if not re.fullmatch(r"[0-9a-f]{40}", str(lock["commit"])):
        raise SystemExit("sync-nawa-recipe: commit must be a full lowercase 40-hex SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", str(lock["sha256"])):
        raise SystemExit("sync-nawa-recipe: sha256 must be 64 lowercase hex characters")
    if not isinstance(lock["rel"], int) or lock["rel"] < 1:
        raise SystemExit("sync-nawa-recipe: rel must be a positive integer")
    if not re.fullmatch(r"[0-9A-Za-z.+_-]+", str(lock["version"])):
        raise SystemExit("sync-nawa-recipe: version contains unsupported characters")
    lock["source"] = (
        f"https://github.com/{lock['repository']}/archive/{lock['commit']}.tar.gz"
    )
    lock["source_dir"] = f"nawa-{lock['commit']}"
    return lock


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def synchronize(text: str, lock: dict) -> str:
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if re.fullmatch(r"\s*\[package\]\s*(?:#.*)?\n?", line)]
    if len(starts) != 1:
        raise SystemExit("sync-nawa-recipe: recipe must contain exactly one [package] table")
    start = starts[0]
    end = next(
        (i for i in range(start + 1, len(lines)) if re.match(r"\s*\[", lines[i])),
        len(lines),
    )
    replacements = {
        "name": quote("nawa"),
        "version": quote(str(lock["version"])),
        "rel": str(lock["rel"]),
        "source": quote(lock["source"]),
        "sha256": quote(lock["sha256"]),
        "source_dir": quote(lock["source_dir"]),
    }
    seen: set[str] = set()
    for i in range(start + 1, end):
        match = re.match(r"^(\s*)([A-Za-z0-9_-]+)(\s*=)(.*?)(\r?\n)?$", lines[i])
        if not match:
            continue
        key = match.group(2)
        if key not in replacements:
            continue
        if key in seen:
            raise SystemExit(f"sync-nawa-recipe: duplicate package.{key}")
        newline = match.group(5) or "\n"
        lines[i] = f"{match.group(1)}{key}{match.group(3)} {replacements[key]}{newline}"
        seen.add(key)

    missing = sorted(set(replacements) - seen)
    if missing:
        raise SystemExit(
            f"sync-nawa-recipe: recipe [package] table is missing: {', '.join(missing)}"
        )

    updated = "".join(lines)
    try:
        package = tomllib.loads(updated).get("package", {})
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"sync-nawa-recipe: generated recipe is invalid TOML: {exc}") from exc
    expected = {
        "name": "nawa",
        "version": lock["version"],
        "rel": lock["rel"],
        "source": lock["source"],
        "sha256": lock["sha256"],
        "source_dir": lock["source_dir"],
    }
    for key, value in expected.items():
        if package.get(key) != value:
            raise SystemExit(f"sync-nawa-recipe: package.{key} did not match the source lock")
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--recipe", type=Path, default=DEFAULT_RECIPE)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail rather than update when the recipe differs from the source lock",
    )
    args = parser.parse_args()
    lock = load_lock(args.lock)
    try:
        current = args.recipe.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"sync-nawa-recipe: cannot read {args.recipe}: {exc}") from exc
    updated = synchronize(current, lock)
    if args.check:
        if updated != current:
            print(
                f"sync-nawa-recipe: {args.recipe} differs from bootstrap/nawa-source.toml",
                file=sys.stderr,
            )
            return 1
        print(f"sync-nawa-recipe: {args.recipe} matches the bootstrap source lock")
        return 0
    if updated != current:
        args.recipe.write_text(updated, encoding="utf-8")
        print(f"sync-nawa-recipe: updated {args.recipe} from the bootstrap source lock")
    else:
        print(f"sync-nawa-recipe: {args.recipe} already matches the bootstrap source lock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
