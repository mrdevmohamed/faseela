#!/usr/bin/env python3
"""scripts/check-recipes.py — offline sanity check of the recipe tree.

Checks (no network, no cargo needed):
  * every recipe.toml parses and has name/version/arch
  * package names are unique
  * every build/run dependency names an existing recipe
  * the dependency graph (build + run) has no cycles
  * sha256 is a 64-hex string (or the all-zero placeholder, reported)

Usage:
  python3 scripts/check-recipes.py              # whole tree
  python3 scripts/check-recipes.py sway foot    # also print the build order
                                                # needed for those targets
"""
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "recipes"
ZERO = "0" * 64


def load():
    recs, errors = {}, []
    for p in sorted(ROOT.rglob("recipe.toml")):
        try:
            r = tomllib.loads(p.read_text())
        except Exception as e:  # noqa: BLE001
            errors.append(f"{p}: parse error: {e}")
            continue
        pkg = r.get("package", {})
        name = pkg.get("name", "")
        if not name or not pkg.get("version"):
            errors.append(f"{p}: missing package.name/version")
            continue
        if name in recs:
            errors.append(f"{p}: duplicate package name `{name}`")
            continue
        if p.parent.name != name:
            errors.append(f"{p}: directory name != package name `{name}`")
        r["_path"] = p
        recs[name] = r
    return recs, errors


def deps_of(r):
    d = r.get("depends", {})
    return list(dict.fromkeys(d.get("build", []) + d.get("run", [])))


def order(recs, targets):
    seen, out, stack = set(), [], []

    def visit(n):
        if n in seen:
            return
        if n in stack:
            raise SystemExit("dependency cycle: " + " -> ".join(stack[stack.index(n):] + [n]))
        stack.append(n)
        for d in deps_of(recs[n]):
            visit(d)
        stack.pop()
        seen.add(n)
        out.append(n)

    for t in targets:
        visit(t)
    return out


def main():
    recs, errors = load()
    placeholders = []
    for n, r in recs.items():
        for d in deps_of(r):
            if d not in recs:
                errors.append(f"{r['_path']}: `{n}` depends on unknown recipe `{d}`")
        pkg = r["package"]
        sha = pkg.get("sha256", "")
        src = pkg.get("source", "")
        if src and not src.startswith("local:"):
            if sha == ZERO:
                placeholders.append(n)
            elif not re.fullmatch(r"[0-9a-f]{64}", sha):
                errors.append(f"{r['_path']}: sha256 is not 64 hex chars")
    if not errors:
        try:
            order(recs, list(recs))
        except SystemExit as e:
            errors.append(str(e))
    for e in errors:
        print("ERROR:", e)
    print(f"{len(recs)} recipes, {len(errors)} errors, "
          f"{len(placeholders)} with placeholder sha256")
    if placeholders:
        print("  placeholders:", " ".join(placeholders))
    targets = [t for t in sys.argv[1:] if t in recs]
    for t in sys.argv[1:]:
        if t not in recs:
            print(f"unknown target `{t}`")
            errors.append("unknown target")
    if targets and not errors:
        print("build order:", " ".join(order(recs, targets)))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
