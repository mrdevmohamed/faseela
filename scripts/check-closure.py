#!/usr/bin/env python3
"""scripts/check-closure.py — would the stage3 self-host proof pass? (in minutes)

    check-closure.py ARCHIVE_DIR FLAVOR

ARCHIVE_DIR holds the published `<name>-<version>-<rel>.nawa.tar.zst` archives
(e.g. `gh release download stable -p '*.nawa.tar.zst'`). The packages of FLAVOR
(flavors.toml + recipes/) are unpacked into one tree, and every ELF file's
DT_NEEDED entry must be provided by some file of that tree: exactly the
"binary needs a library that is not in the root" test of bootstrap/final-root.sh,
run on the packages the repository already has instead of after a 2-hour core
build. A missing library names the package that links it, so the fix is one
line in that recipe's depends.run (e.g. perl -> libxcrypt).
Exit: 0 ok, 1 a library is missing, 2 usage/error. Packages without an archive
in ARCHIVE_DIR are listed and skipped (the check then covers less, never wrongly fails).
"""
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import flavor  # noqa: E402  (fetched from faseela-repo next to flavors.toml)

IGNORE = {"linux-vdso.so.1"}


def ids(recipes: Path):
    out = {}
    for f in recipes.glob("*/*/recipe.toml"):
        p = tomllib.loads(f.read_text(encoding="utf-8"))["package"]
        out[p["name"]] = f"{p['name']}-{p['version']}-{p.get('rel', 1)}"
    return out


def needed(path: Path):
    r = subprocess.run(["readelf", "-d", str(path)], capture_output=True, text=True)
    res = []
    for line in r.stdout.splitlines():
        if "(NEEDED)" in line and "[" in line:
            res.append(line.split("[", 1)[1].split("]", 1)[0])
    return res


def is_elf(path: Path):
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    arch = Path(argv[1])
    flavors = flavor.load_flavors(ROOT / "flavors.toml")
    recipes = flavor.load_recipes(ROOT / "recipes")
    pid = ids(ROOT / "recipes")
    pkgs = flavor.resolve(flavors, recipes, argv[2])
    skipped, owner, provided = [], {}, set()
    with tempfile.TemporaryDirectory() as tmp:
        for p in pkgs:
            a = arch / f"{pid[p]}.nawa.tar.zst"
            if not a.is_file():
                skipped.append(p)
                continue
            d = Path(tmp) / p
            d.mkdir()
            r = subprocess.run(["tar", "-xf", str(a), "-C", str(d), "--no-same-owner"],
                               capture_output=True, text=True)
            if r.returncode:
                print(f"check-closure: cannot unpack {a.name}: {r.stderr.strip()}", file=sys.stderr)
                return 2
            owner[p] = d
            for f in d.rglob("*"):
                if f.is_file() or f.is_symlink():
                    provided.add(f.name)
        bad = {}
        for p, d in owner.items():
            for f in d.rglob("*"):
                if f.is_symlink() or not f.is_file() or not is_elf(f):
                    continue
                for n in needed(f):
                    if n not in provided and n not in IGNORE:
                        bad.setdefault((p, n), []).append(str(f.relative_to(d)))
    print(f"closure of '{argv[2]}': {len(owner)} packages checked, {len(skipped)} without an archive"
          + (f" ({' '.join(skipped)})" if skipped else ""))
    for (p, n), files in sorted(bad.items()):
        print(f"::error title=closure::{p}: {files[0]} needs {n}, which no package of "
              f"'{argv[2]}' provides — add its package to {p}'s depends.run in faseela-repo")
        print(f"  {p}: needs {n} ({len(files)} file(s), e.g. {files[0]})")
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (flavor.FlavorError, KeyError, OSError) as e:
        print(f"check-closure: {e}", file=sys.stderr)
        sys.exit(2)
