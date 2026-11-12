#!/usr/bin/env python3
"""Build a release matrix from faseela-repo's flavors.toml.

All flavors beginning with iso- are packed as bootable ISOs. All flavors
beginning with rootfs- are packed as rootfs archives. Other flavors can still
be selected explicitly; they are packed as rootfs archives.

Selection:
  all                 every publishable iso-* and rootfs-* flavor
  core                no flavor images; only prepare the bootstrap seed
  iso-xfce rootfs-min one or more exact flavor names (spaces or commas)
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import flavor  # noqa: E402


def artifact(name):
    if name.startswith("iso-"):
        slug = name[4:]
        if name == "iso-nogui":
            filename, volume = "faseela-x86_64.iso", "FASEELA"
        else:
            filename = f"faseela-{slug}-x86_64.iso"
            volume = ("FASEELA_" + re.sub(r"[^A-Z0-9_]", "_", slug.upper()))[:32]
        return {"variant": name, "kind": "iso", "iso": filename, "vol": volume}

    if name == "rootfs-min":
        filename = "faseela-x86_64-rootfs-min.tar.zst"
    else:
        filename = f"faseela-{name}-x86_64-rootfs.tar.zst"
    return {"variant": name, "kind": "rootfs", "rootfs": filename}


def build_plan(selection, flavors, recipes):
    tokens = [x for x in re.split(r"[\s,]+", selection.strip()) if x]
    if not tokens:
        raise ValueError("outputs is empty; use 'all', 'core', or one or more flavor names")
    if "all" in tokens and len(tokens) != 1:
        raise ValueError("'all' cannot be combined with other output names")
    if "core" in tokens and len(tokens) != 1:
        raise ValueError("'core' cannot be combined with flavor names")

    if tokens == ["core"]:
        names = []
    elif tokens == ["all"]:
        names = sorted(
            n for n in flavors
            if n.startswith(("iso-", "rootfs-"))
        )
    else:
        names = list(dict.fromkeys(tokens))
        reserved = sorted(set(names) & {"bootstrap", "seed"})
        if reserved:
            raise ValueError(
                f"{', '.join(reserved)} are internal bootstrap flavors, not image outputs"
            )
        unknown = sorted(set(names) - set(flavors))
        if unknown:
            raise ValueError(
                f"unknown flavor(s): {', '.join(unknown)}; available: {', '.join(sorted(flavors))}"
            )

    # Resolve every selected flavor now, so an invalid dependency graph fails
    # in the plan job rather than after the core build has consumed runner time.
    for name in names:
        flavor.resolve(flavors, recipes, name)

    matrix = [artifact(name) for name in names]
    isos = [item for item in matrix if item["kind"] == "iso"]
    return {
        "matrix": {"include": matrix},
        "isos": {"include": isos},
        "has_iso": bool(isos),
        "has_variants": bool(matrix),
        "has_rootfs_min": any(item["variant"] == "rootfs-min" for item in matrix),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--selection", default="all", help="all, core, or exact flavor names")
    ap.add_argument("--flavors", type=Path, default=HERE.parent / "flavors.toml")
    ap.add_argument("--recipes", type=Path, default=HERE.parent / "recipes")
    args = ap.parse_args()
    try:
        flavors = flavor.load_flavors(args.flavors)
        recipes = flavor.load_recipes(args.recipes)
        result = build_plan(args.selection, flavors, recipes)
    except (ValueError, flavor.FlavorError, OSError, KeyError) as exc:
        print(f"plan-flavors: {exc}", file=sys.stderr)
        return 2
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
