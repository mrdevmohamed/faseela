#!/usr/bin/env python3
"""Fail fast when a recipe's source cannot be downloaded.

Probes every recipe's `source` and `mirrors` (a ranged GET of the first byte,
so no full download) and exits 1 only when NO url of a recipe answers. A
recipe whose primary url is down but another candidate answers is a warning.
The candidates are the same ones nawa tries at build time (fetch.rs
`candidate_urls`): for a GNU url the equivalent urls on the other GNU mirrors,
then the recipe's own `mirrors`. A single flaky mirror therefore cannot fail
the run (it failed v1.0.0 on mirrors.kernel.org/gnu/mpfr while nawa itself
would have fetched the file from ftpmirror.gnu.org).
Run it before the multi-hour build: an unreachable host then costs a minute,
not the hours that stage1/stage2 take to reach that package.

    scripts/check-sources.py [--jobs N] [--dry-run] [recipes-dir]
"""
import argparse, glob, os, sys, time, tomllib, threading, urllib.request, urllib.error
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlsplit

# keep in step with nawa's src/fetch.rs candidate_urls
GNU_PREFIXES = [
    "https://mirrors.kernel.org/gnu/",
    "https://ftp.gnu.org/gnu/",
    "https://ftpmirror.gnu.org/",
    "https://mirror.us-midwest-1.nexcess.net/gnu/",
    "https://mirrors.ocf.berkeley.edu/gnu/",
]
GNU_ALTERNATES = [
    "https://ftpmirror.gnu.org/",
    "https://ftp.gnu.org/gnu/",
    "https://mirrors.kernel.org/gnu/",
    "https://mirrors.ocf.berkeley.edu/gnu/",
]

def candidates(url, extra=()):
    out = [url]
    for prefix in GNU_PREFIXES:
        if url.startswith(prefix):
            rest = url[len(prefix):]
            out += [a + rest for a in GNU_ALTERNATES if a + rest not in out]
            break
    out += [m for m in extra if m not in out]
    return out

def urls(path):
    p = tomllib.load(open(path, "rb"))["package"]
    if "source" not in p:
        return None, []
    ver = str(p.get("version", ""))
    sub = lambda u: u.replace("%{version}", ver)
    return p["name"], candidates(sub(p["source"]), [sub(m) for m in p.get("mirrors", [])])

# at most this many concurrent probes per host: 16 parallel requests at
# mirrors.kernel.org (39 recipes live there) are what tripped it
HOST_LIMIT = 4
_hosts = defaultdict(lambda: threading.BoundedSemaphore(HOST_LIMIT))
_hosts_lock = threading.Lock()

def probe(url, tries=3, delay=float(os.environ.get("CHECK_SOURCES_DELAY", "3"))):
    with _hosts_lock:
        sem = _hosts[urlsplit(url).netloc]
    with sem:
        return _probe(url, tries, delay)

def _probe(url, tries, delay):
    last = ""
    for i in range(tries):
        if i:
            time.sleep(delay * i)  # back off: 3 s, then 6 s
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
    # first candidate that answers wins; the rest are not probed
    name, us = item
    res = []
    for u in us:
        r = (u, *probe(u))
        res.append(r)
        if r[1]:
            break
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
