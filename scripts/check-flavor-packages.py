#!/usr/bin/env python3
"""scripts/check-flavor-packages.py — is every package of a flavor in the repository?

    check-flavor-packages.py ASSETS_FILE FLAVOR [FLAVOR...]

ASSETS_FILE lists the file names of the package repository (one per line, e.g.
`gh release view stable --json assets --jq '.assets[].name'`). For each flavor
(flavors.toml + recipes/, as fetched by bootstrap/fetch-recipes.sh) the packages
whose archive `<name>-<version>-<rel>.nawa.tar.zst` is not listed are printed,
and the exit status is 1. The ISO workflow runs this before its multi-hour core
build, so a flavor that cannot be installed fails (or warns) in a minute.
The bootstrap core itself is not expected in the repository: it is built by
the workflow, not installed.
"""
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import flavor  # noqa: E402  (fetched from faseela-repo next to flavors.toml)


def ids(recipes: Path):
    out = {}
    for f in recipes.glob("*/*/recipe.toml"):
        p = tomllib.loads(f.read_text(encoding="utf-8"))["package"]
        out[p["name"]] = f"{p['name']}-{p['version']}-{p.get('rel', 1)}"
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    assets = {a.strip() for a in Path(argv[1]).read_text().splitlines() if a.strip()}
    flavors = flavor.load_flavors(ROOT / "flavors.toml")
    recipes = flavor.load_recipes(ROOT / "recipes")
    pid = ids(ROOT / "recipes")
    bootstrap = set(flavor.resolve(flavors, recipes, "bootstrap"))
    bad = 0
    for name in argv[2:]:
        want = [p for p in flavor.resolve(flavors, recipes, name) if p not in bootstrap]
        missing = [p for p in want if f"{pid[p]}.nawa.tar.zst" not in assets]
        if missing:
            bad += 1
            print(f"{name}: {len(missing)} of {len(want)} packages are not in the repository: {' '.join(missing)}")
        else:
            print(f"{name}: all {len(want)} packages are in the repository")
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (flavor.FlavorError, KeyError, OSError) as e:
        print(f"check-flavor-packages: {e}", file=sys.stderr)
        sys.exit(2)
