#!/usr/bin/env python3
"""scripts/fill-sha256.py — pin / re-pin the sha256 of recipe sources.

Recipes under recipes/gui/* may ship with the all-zero placeholder (they were
written without network access). This downloads the source tarball, computes
its sha256 and rewrites the recipe in place. Review the result (`git diff`):
the pin is what guarantees integrity, so only run this on a network you trust
and compare against upstream's published checksums where they exist.

Usage:
  python3 scripts/fill-sha256.py --dry-run          # list URLs of placeholders
  python3 scripts/fill-sha256.py                    # fill every placeholder
  python3 scripts/fill-sha256.py -r fcft            # (re)compute ONE recipe, always
  python3 scripts/fill-sha256.py -r fcft -r foot    # several (repeat or comma list)
  python3 scripts/fill-sha256.py -r fcft foot sway # several names after one -r
  python3 scripts/fill-sha256.py -r fcft,foot --dry-run
  python3 scripts/fill-sha256.py --all              # recompute EVERY recipe
  python3 scripts/fill-sha256.py sway wlroots       # legacy: only if still a placeholder
  python3 scripts/fill-sha256.py --repin foot       # legacy: same as -r foot

-r/--recipe selects recipes by name and ALWAYS recomputes the hash (real or
placeholder), re-downloading the source instead of trusting the local cache.
Use --use-cache to allow the cached download.
Every download is checked (Content-Length, and the archive is read end to end)
so a truncated or corrupt file is rejected, never pinned; --no-verify skips it.
A connection cut mid-download is resumed (HTTP Range) up to --retries times. Unknown names are an error.
A 404 means the pinned version no longer exists upstream: bump `version`
(and `rel`) in the recipe, then re-run.
"""
import argparse
import hashlib
import http.client
import re
import sys
import tarfile
import tomllib
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "recipes"
ZERO = "0" * 64
CACHE = Path.home() / ".cache" / "nawa-fill-sha256"
SHA_LINE = re.compile(r'(?m)^sha256 = "[0-9a-f]{64}"')


def expand(s, pkg):
    return (s.replace("%{version}", pkg["version"])
             .replace("%{name}", pkg["name"])
             .replace("%{rel}", str(pkg.get("rel", 1))))


def verify_archive(path, url):
    """Fully read the archive so a truncated/corrupt/HTML-error download is
    rejected instead of being hashed and pinned."""
    name = url.split("?")[0].lower()
    if name.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            bad = z.testzip()
            if bad:
                raise ValueError(f"corrupt zip member: {bad}")
    elif re.search(r"\.(tar|tar\.(gz|bz2|xz|zst)|tgz|tbz2|txz)$", name):
        if name.endswith(".zst"):
            return  # tarfile cannot read zstd; size check above still applies
        with tarfile.open(path) as t:
            for _ in t:  # iterating decompresses the whole stream (CRC checked)
                pass


def download(url, part, retries):
    """Download to `part`, resuming with HTTP Range after a cut connection.
    urllib does not raise when the server drops the connection mid-body, so the
    received size is compared with the advertised one and the rest re-requested."""
    total = None
    last = None
    for attempt in range(retries + 1):
        got = part.stat().st_size if part.exists() else 0
        if total is not None and got == total:
            return
        headers = {"User-Agent": "nawa-fill-sha256"}
        if got:
            headers["Range"] = f"bytes={got}-"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers),
                                        timeout=60) as r:
                if got and r.status == 206:
                    mode = "ab"
                    m = re.match(r"bytes \d+-\d+/(\d+)", r.headers.get("Content-Range", ""))
                    total = int(m.group(1)) if m else total
                else:  # fresh start, or the server ignored Range: begin again
                    mode = "wb"
                    cl = r.headers.get("Content-Length")
                    total = int(cl) if cl else None
                with open(part, mode) as f:
                    while chunk := r.read(1 << 20):
                        f.write(chunk)
        except urllib.error.HTTPError as e:
            if e.code == 416:      # our offset is not satisfiable: start over
                part.unlink(missing_ok=True)
                last = e
            elif e.code < 500:
                raise
            else:
                last = e
        except (OSError, http.client.HTTPException) as e:  # reset, timeout, IncompleteRead
            last = e
        got = part.stat().st_size if part.exists() else 0
        if total is None or got == total:
            if got == 0:
                raise OSError("empty download")
            return
        if attempt < retries:
            print(f"     retry {attempt + 1}/{retries}: {got} of {total} bytes"
                  f"{f' ({last})' if last else ''}", file=sys.stderr)
            time.sleep(min(2 * (attempt + 1), 10))
    raise OSError(f"truncated download: got {got} of {total} bytes after {retries} retries")


def fetch(url, use_cache, verify=True, retries=8):
    CACHE.mkdir(parents=True, exist_ok=True)
    dest = CACHE / hashlib.sha1(url.encode()).hexdigest()
    if dest.exists() and not use_cache:
        dest.unlink()  # forced refresh: never re-hash a stale download
    if not dest.exists():
        part = dest.with_suffix(".part")
        part.unlink(missing_ok=True)
        try:
            download(url, part, retries)
            if verify:
                verify_archive(part, url)
        except BaseException:
            part.unlink(missing_ok=True)
            raise
        part.rename(dest)
    h = hashlib.sha256()
    with open(dest, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def parse_args():
    ap = argparse.ArgumentParser(
        description="Pin or re-pin recipe source sha256 hashes.",
        epilog="See the module docstring (head of this file) for examples.")
    ap.add_argument("names", nargs="*", metavar="NAME",
                    help="legacy: recipes to fill (only if still a placeholder; "
                         "add --repin to force)")
    ap.add_argument("-r", "--recipe", action="append", nargs="+", default=[], metavar="NAME",
                    help="recipe(s) to (re)compute, always; several names, repeats "
                         "or comma lists are all fine")
    ap.add_argument("--all", action="store_true",
                    help="(re)compute EVERY recipe that has a downloadable source")
    ap.add_argument("--repin", action="store_true",
                    help="legacy: force-recompute the positional NAMEs")
    ap.add_argument("--dry-run", action="store_true", help="print URLs, change nothing")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the archive integrity check (odd non-archive sources)")
    ap.add_argument("--retries", type=int, default=8, metavar="N",
                    help="resume/retry a cut download up to N times (default 8)")
    ap.add_argument("--use-cache", action="store_true",
                    help="reuse a previously downloaded tarball instead of re-fetching")
    a = ap.parse_args()
    a.recipe = [n for group in a.recipe for chunk in group
                for n in chunk.split(",") if n]
    if a.repin and not (a.names or a.recipe):
        ap.error("--repin needs at least one recipe name (or use -r NAME)")
    return a


def main():
    a = parse_args()
    force = set(a.recipe)                           # always recompute
    if a.repin:
        force |= set(a.names)
    fill_only = set(a.names) - force                # legacy: only placeholders
    wanted = force | fill_only

    recipes = {}
    for p in sorted(ROOT.rglob("recipe.toml")):
        text = p.read_text()
        pkg = tomllib.loads(text)["package"]
        recipes[pkg["name"]] = (p, text, pkg)

    if a.all:
        force |= {n for n, (_, _, pkg) in recipes.items()
                  if pkg.get("source") and not pkg["source"].startswith("local:")}
        wanted = force | fill_only

    unknown = sorted(wanted - recipes.keys())
    if unknown:
        print(f"error: unknown recipe(s): {', '.join(unknown)}", file=sys.stderr)
        sys.exit(2)

    failed = 0
    for name, (p, text, pkg) in recipes.items():
        src, sha = pkg.get("source", ""), pkg.get("sha256", "")
        if wanted and name not in wanted:
            continue
        if not src or src.startswith("local:"):
            if name in wanted:
                print(f"skip {name}: no downloadable source")
            continue
        if not wanted and sha != ZERO:              # default mode: placeholders only
            continue
        if name in fill_only and sha != ZERO:
            print(f"skip {name}: already pinned (use -r {name} to recompute)")
            continue
        url = expand(src, pkg)
        if a.dry_run:
            print(f"{name}: {url}")
            continue
        try:
            digest = fetch(url, a.use_cache, not a.no_verify, a.retries)
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {name}: {url}\n     {e}")
            failed += 1
            continue
        if not SHA_LINE.search(text):
            print(f"FAIL {name}: no 'sha256 = \"<64 hex>\"' line to update in {p}")
            failed += 1
            continue
        if digest == sha:
            print(f"same {name}: {digest}")
            continue
        p.write_text(SHA_LINE.sub(f'sha256 = "{digest}"', text, count=1))
        old = "placeholder" if sha == ZERO else sha
        print(f"ok   {name}: {digest}\n     (was {old})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
