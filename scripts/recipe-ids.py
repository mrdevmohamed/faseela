#!/usr/bin/env python3
"""scripts/recipe-ids.py — what the recipe tree builds.

    scripts/recipe-ids.py [RECIPES_DIR]
        one line per recipe: "<category> <name> <id>"
        id = <name>-<version>-<rel>, the stem of the archive dpm builds
        (<id>.dpm.tar.zst, see Recipe::id in pkgmgr)

    scripts/recipe-ids.py --stale PKG_DIR [RECIPES_DIR]
        names of the *.dpm.tar.zst files in PKG_DIR that belong to a package
        which still has a recipe but whose version/rel has since changed, i.e.
        archives a newer build has replaced. Archives of packages that no
        longer have a recipe are NOT reported (removing a package is a
        decision for a human).

Used by .github/workflows/packages.yml to expand "@extra" / "@all" into
package names and to prune superseded archives from the package repository.
"""
import re
import sys
import tomllib
from pathlib import Path

SUFFIX = ".dpm.tar.zst"


def load(root: Path):
    """-> list of (category, name, id); prints problems to stderr."""
    out, bad = [], False
    for f in sorted(root.glob("*/*/recipe.toml")):
        try:
            pkg = tomllib.loads(f.read_text(encoding="utf-8"))["package"]
            name, version = pkg["name"], pkg["version"]
            rel = pkg.get("rel", 1)  # same default as the Rust side
        except (tomllib.TOMLDecodeError, KeyError) as e:
            print(f"recipe-ids: {f}: {e!r}", file=sys.stderr)
            bad = True
            continue
        out.append((f.parent.parent.name, name, f"{name}-{version}-{rel}"))
    return out, bad


def stale(pkg_dir: Path, recipes):
    current = {i for _, _, i in recipes}
    names = [n for _, n, _ in recipes]
    for f in sorted(pkg_dir.glob("*" + SUFFIX)):
        stem = f.name[: -len(SUFFIX)]
        if stem in current:
            continue
        if any(re.fullmatch(re.escape(n) + r"-\d.*-\d+", stem) for n in names):
            yield f.name


def main(argv) -> int:
    if argv and argv[0] == "--stale":
        if len(argv) < 2:
            print("usage: recipe-ids.py --stale PKG_DIR [RECIPES_DIR]", file=sys.stderr)
            return 2
        recipes, bad = load(Path(argv[2] if len(argv) > 2 else "recipes"))
        for name in stale(Path(argv[1]), recipes):
            print(name)
        return 1 if bad else 0
    root = Path(argv[0] if argv else "recipes")
    if not root.is_dir():
        print(f"recipe-ids: {root} is not a directory", file=sys.stderr)
        return 2
    recipes, bad = load(root)
    for row in recipes:
        print(*row)
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
