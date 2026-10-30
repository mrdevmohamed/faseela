#!/usr/bin/env python3
"""Fail fast when a recipe's source cannot be downloaded.

Probes every recipe's `source` and `mirrors` (a ranged GET of the first byte,
so no full download) and exits 1 only when NO url of a recipe answers. A
recipe whose primary url is down but whose mirror answers is a warning.
Run it before the multi-hour build: an unreachable host then costs a minute,
not the hours that stage1/stage2 take to reach that package.

    scripts/check-sources.py [--jobs N] [--dry-run] [recipes-dir]
"""
import argparse, glob, os, sys, tomllib, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

def urls(path):
    p = tomllib.load(open(path, "rb"))["package"]
    if "source" not in p:
        return None, []
    ver = str(p.get("version", ""))
    sub = lambda u: u.replace("%{version}", ver)
    return p["name"], [sub(p["source"])] + [sub(m) for m in p.get("mirrors", [])]

def probe(url, tries=3):
    last = ""
    for _ in range(tries):
        req = urllib.request.Request(url, headers={"Range": "bytes=0-0", "User-Agent": "faseela-check-sources"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return True, str(r.status)
        except urllib.error.HTTPError as e:
            last = str(e.code)
            if e.code in (404, 403, 410):
                break
        except Exception as e:
            last = type(e).__name__
    return False, last

def check(item):
    name, us = item
    res = [(u, *probe(u)) for u in us]
    return name, res

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recipes", nargs="?", default="recipes")
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--dry-run", action="store_true", help="only parse recipes, no network")
    a = ap.parse_args()
    items = []
    for f in sorted(glob.glob(os.path.join(a.recipes, "*", "*", "recipe.toml"))):
        name, us = urls(f)
        if name:
            items.append((name, us))
    if a.dry_run:
        print(f"{len(items)} recipes with a source, {sum(len(u) for _, u in items)} urls")
        return 0
    bad = warn = 0
    with ThreadPoolExecutor(a.jobs) as ex:
        for name, res in ex.map(check, items):
            ok = [r for r in res if r[1]]
            if not ok:
                bad += 1
                print(f"::error::{name}: no source url reachable: " + ", ".join(f"{u} ({c})" for u, _, c in res))
            elif not res[0][1]:
                warn += 1
                print(f"::warning::{name}: primary url down ({res[0][2]}), mirror ok: {ok[0][0]}")
    print(f"checked {len(items)} recipes: {bad} unreachable, {warn} on mirror only")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
