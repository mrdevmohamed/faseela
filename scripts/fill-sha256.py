#!/usr/bin/env python3
"""scripts/fill-sha256.py — pin the sha256 of recipes that still carry the
all-zero placeholder (recipes/gui/* ship that way: they were written without
network access).

For every recipe whose sha256 is the placeholder this downloads the source
tarball, computes the hash and rewrites the recipe in place. Review the
result (`git diff`) — the pin is what guarantees integrity, so only run this
on a network you trust and compare against upstream's published checksums
where they exist.

Usage:
  python3 scripts/fill-sha256.py --dry-run       # just print the URLs
  python3 scripts/fill-sha256.py                 # fill every placeholder
  python3 scripts/fill-sha256.py sway wlroots    # only these recipes
  python3 scripts/fill-sha256.py --repin foot    # recompute a real hash
A 404 means the pinned version no longer exists upstream: bump `version`
(and `rel`) in the recipe, then re-run.
"""
import hashlib
import re
import sys
import tomllib
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "recipes"
ZERO = "0" * 64
CACHE = Path.home() / ".cache" / "dpm-fill-sha256"


def expand(s, pkg):
    return (s.replace("%{version}", pkg["version"])
             .replace("%{name}", pkg["name"])
             .replace("%{rel}", str(pkg.get("rel", 1))))


def fetch(url):
    CACHE.mkdir(parents=True, exist_ok=True)
    dest = CACHE / hashlib.sha1(url.encode()).hexdigest()
    if not dest.exists():
        req = urllib.request.Request(url, headers={"User-Agent": "dpm-fill-sha256"})
        with urllib.request.urlopen(req, timeout=60) as r, open(dest.with_suffix(".part"), "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        dest.with_suffix(".part").rename(dest)
    h = hashlib.sha256()
    with open(dest, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    repin = "--repin" in args
    only = {a for a in args if not a.startswith("--")}
    failed = 0
    for p in sorted(ROOT.rglob("recipe.toml")):
        text = p.read_text()
        pkg = tomllib.loads(text)["package"]
        src, sha = pkg.get("source", ""), pkg.get("sha256", "")
        if not src or src.startswith("local:"):
            continue
        if only and pkg["name"] not in only:
            continue
        if not only and not repin and sha != ZERO:
            continue
        if not only and repin:
            continue  # --repin needs explicit names
        if only and sha != ZERO and not repin:
            continue
        url = expand(src, pkg)
        if dry:
            print(f"{pkg['name']}: {url}")
            continue
        try:
            digest = fetch(url)
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {pkg['name']}: {url}\n     {e}")
            failed += 1
            continue
        new = re.sub(r'(?m)^sha256 = "[0-9a-f]{64}"', f'sha256 = "{digest}"', text, count=1)
        p.write_text(new)
        print(f"ok   {pkg['name']}: {digest}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
