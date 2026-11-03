#!/usr/bin/env python3
"""Resolve selected Stage 3 Toolchain packages in Nawa dependency order."""
from __future__ import annotations
import argparse, re, sys, tomllib
from pathlib import Path

class SelectionError(Exception):
    """Invalid Stage 3 selection or dependency order."""

def split_names(value: str) -> list[str]:
    return [item for item in re.split(r"[\s,]+", value.strip()) if item]

def load_recipes(root: Path) -> dict[str, dict]:
    recipes: dict[str, dict] = {}
    for path in sorted(root.glob("*/*/recipe.toml")):
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
            package = data["package"]
            name = package["name"]
            category = path.parent.parent.name
            if name in recipes:
                raise SelectionError(f"duplicate recipe name: {name}")
            deps = data.get("depends", {})
            recipes[name] = {"category": category, "build": list(deps.get("build", [])),
                             "run": list(deps.get("run", []))}
        except (OSError, tomllib.TOMLDecodeError, KeyError, TypeError) as exc:
            raise SelectionError(f"cannot read recipe {path}: {exc}") from exc
    return recipes

def resolve_selection(recipes: dict[str, dict], requested: list[str], order: list[str]) -> list[str]:
    if not requested:
        raise SelectionError("no Stage 3 packages were selected")
    toolchain = {name for name, item in recipes.items() if item["category"] == "toolchain"}
    for name in requested:
        if name not in recipes:
            raise SelectionError(f"unknown package '{name}'")
        if name not in toolchain:
            raise SelectionError(f"'{name}' is not in recipes/toolchain")
    closure: set[str] = set()
    def visit(name: str) -> None:
        if name in closure:
            return
        closure.add(name)
        for dep in recipes[name]["build"] + recipes[name]["run"]:
            if dep in toolchain:
                visit(dep)
    for name in requested:
        visit(name)
    ordered: list[str] = []
    seen: set[str] = set()
    for name in order:
        if name and name not in seen:
            seen.add(name)
            ordered.append(name)
    missing = sorted(closure - seen)
    if missing:
        raise SelectionError("Nawa dependency order is missing Toolchain package(s): " + ", ".join(missing))
    resolved = [name for name in ordered if name in closure]
    if set(resolved) != closure:
        raise SelectionError("could not resolve every selected Toolchain dependency")
    return resolved

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipes", type=Path, required=True)
    parser.add_argument("--packages", required=True, help="Toolchain recipe names, comma/space separated")
    args = parser.parse_args(argv)
    try:
        recipes = load_recipes(args.recipes)
        order = [line.strip() for line in sys.stdin if line.strip()]
        print("\n".join(resolve_selection(recipes, split_names(args.packages), order)))
        return 0
    except (SelectionError, OSError) as exc:
        print(f"stage3 package selection: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
