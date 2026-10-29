#!/usr/bin/env python3
"""scripts/rootfs-closure.py — runtime-dependency closure of recipes.

Prints the packages needed to make REQUEST installable (REQUEST plus every
[depends].run dependency, transitively), ONE per line, dependencies first.
Used by bootstrap/mkrootfs-min.sh to decide what goes into the small
base-devel rootfs, and by CI to prove that closure still resolves.

Usage: rootfs-closure.py RECIPES_DIR PKG [PKG...]
Needs Python >= 3.11 (tomllib). A dependency without a recipe is an error.
"""
import pathlib
import sys
import tomllib


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    root = pathlib.Path(argv[1])
    recipes = {p.parent.name: p for p in sorted(root.glob("*/*/recipe.toml"))}
    if not recipes:
        print(f"rootfs-closure: no recipes under {root}", file=sys.stderr)
        return 1

    order, state = [], {}  # state: 1 = on the stack, 2 = done

    def visit(name, parent):
        if state.get(name):  # done, or a cycle: either way do not recurse again
            return
        if name not in recipes:
            who = f"needed by {parent}" if parent else "requested"
            sys.exit(f"rootfs-closure: no recipe named '{name}' ({who})")
        state[name] = 1
        data = tomllib.loads(recipes[name].read_text())
        for dep in data.get("depends", {}).get("run", []):
            visit(dep, name)
        state[name] = 2
        order.append(name)

    for want in argv[2:]:
        visit(want, None)
    print("\n".join(order))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
