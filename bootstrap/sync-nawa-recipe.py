#!/usr/bin/env python3
"""Synchronize the Nawa recipe with Bootstrap's independent source lock.

The bootstrap source lock is authoritative for the stage-2 seed build and the
Nawa package installed in the finished system. The recipe uses the current
multi-source schema; the package source marker prevents old Nawa binaries from
silently treating it as an empty-source recipe.
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
SCHEMA_MARKER = "local:/nawa-schema-2-requires-a-newer-nawa"
SOURCE_NAME = "nawa"


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
        raise SystemExit("sync-nawa-recipe: commit must be a full 40-character lowercase SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", str(lock["sha256"])):
        raise SystemExit("sync-nawa-recipe: sha256 must be 64 lowercase hex characters")
    if not isinstance(lock["rel"], int) or lock["rel"] < 1:
        raise SystemExit("sync-nawa-recipe: rel must be a positive integer")
    if not re.fullmatch(r"[0-9A-Za-z.+_-]+", str(lock["version"])):
        raise SystemExit("sync-nawa-recipe: version contains unsupported characters")

    lock["url"] = (
        f"https://github.com/{lock['repository']}/archive/{lock['commit']}.tar.gz"
    )
    return lock


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def replace_table_fields(text: str, header: str, fields: dict[str, str], description: str) -> str:
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if re.fullmatch(
        re.escape(header) + r"\s*(?:#.*)?\n?", line
    )]
    if len(starts) != 1:
        raise SystemExit(f"sync-nawa-recipe: expected exactly one {header} table")
    start = starts[0]
    end = next(
        (i for i in range(start + 1, len(lines)) if re.match(r"\s*\[", lines[i])),
        len(lines),
    )
    seen: set[str] = set()
    for i in range(start + 1, end):
        match = re.match(r"^(\s*)([A-Za-z0-9_-]+)(\s*=)(.*?)(\r?\n)?$", lines[i])
        if not match:
            continue
        key = match.group(2)
        if key not in fields:
            continue
        if key in seen:
            raise SystemExit(f"sync-nawa-recipe: duplicate {description}.{key}")
        newline = match.group(5) or "\n"
        lines[i] = f"{match.group(1)}{key}{match.group(3)} {fields[key]}{newline}"
        seen.add(key)

    missing = [key for key in fields if key not in seen]
    if missing:
        insertion = end
        additions = [f"{key} = {fields[key]}\n" for key in missing]
        lines[insertion:insertion] = additions
    return "".join(lines)


def synchronize(text: str, lock: dict) -> str:
    updated = replace_table_fields(
        text,
        "[package]",
        {
            "name": quote("nawa"),
            "version": quote(str(lock["version"])),
            "rel": str(lock["rel"]),
            "source": quote(SCHEMA_MARKER),
        },
        "package",
    )

    parsed = tomllib.loads(updated)
    sources = parsed.get("package", {}).get("sources")
    if not isinstance(sources, list):
        raise SystemExit("sync-nawa-recipe: recipe must contain [[package.sources]]")

    matches = [item for item in sources if item.get("name") == SOURCE_NAME]
    if len(matches) != 1:
        raise SystemExit(
            f"sync-nawa-recipe: expected exactly one package source named {SOURCE_NAME!r}"
        )

    lines = updated.splitlines(keepends=True)
    headers = [
        i for i, line in enumerate(lines)
        if re.fullmatch(r"\s*\[\[package\.sources\]\]\s*(?:#.*)?\n?", line)
    ]
    target_start = None
    target_end = len(lines)
    for index, start in enumerate(headers):
        end = headers[index + 1] if index + 1 < len(headers) else next(
            (i for i in range(start + 1, len(lines)) if re.match(r"\s*\[", lines[i])),
            len(lines),
        )
        block = "".join(lines[start:end])
        if re.search(r'(?m)^name\s*=\s*"nawa"\s*$', block):
            if target_start is not None:
                raise SystemExit("sync-nawa-recipe: duplicate nawa source table")
            target_start, target_end = start, end
    if target_start is None:
        raise SystemExit("sync-nawa-recipe: [[package.sources]] named nawa not found")

    block = "".join(lines[target_start:target_end])
    for key, value in {"url": quote(lock["url"]), "sha256": quote(lock["sha256"])}.items():
        pattern = rf"(?m)^(\s*{key}\s*=\s*).*$"
        block, count = re.subn(pattern, lambda m: m.group(1) + value, block, count=1)
        if count != 1:
            raise SystemExit(f"sync-nawa-recipe: source {SOURCE_NAME!r} is missing {key}")
    lines[target_start:target_end] = [block]
    updated = "".join(lines)

    try:
        result = tomllib.loads(updated)
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"sync-nawa-recipe: generated recipe is invalid TOML: {exc}") from exc

    package = result.get("package", {})
    expected = {
        "name": "nawa",
        "version": lock["version"],
        "rel": lock["rel"],
        "source": SCHEMA_MARKER,
    }
    for key, value in expected.items():
        if package.get(key) != value:
            raise SystemExit(f"sync-nawa-recipe: package.{key} did not match the source lock")
    source = [item for item in package["sources"] if item.get("name") == SOURCE_NAME][0]
    if source.get("url") != lock["url"] or source.get("sha256") != lock["sha256"]:
        raise SystemExit("sync-nawa-recipe: package.sources[nawa] did not match the source lock")
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--recipe", type=Path, default=DEFAULT_RECIPE)
    parser.add_argument(
        "--check", action="store_true",
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
