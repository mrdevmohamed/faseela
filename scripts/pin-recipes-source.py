#!/usr/bin/env python3
"""scripts/pin-recipes-source.py — pin dpm-recipes and dpm-repo to one commit
of the official repository (github.com/mrdevmohamed/faseela).

Both recipes download  https://github.com/<REPO>/archive/<commit>.tar.gz  and
verify it against a sha256, so they need a commit, its date (the `version`)
and the tarball hash. This script writes all of them:

    python3 scripts/pin-recipes-source.py               # commit = git HEAD
    python3 scripts/pin-recipes-source.py <40-hex sha>  # an explicit commit
    python3 scripts/pin-recipes-source.py --no-fill     # skip the download/hash

The commit must already be PUSHED to GitHub (the hash is computed from the
tarball GitHub serves) and, for dpm-repo, must contain pkgmgr/dist/dpm.pub.

A commit cannot contain the hash of its own tarball, so the tree that gets
shipped is the one at the pinned commit - normally one commit behind the
commit that holds the pin. That is intended.

`version` is the commit date (YYYY.MM.DD); `rel` restarts at 1 for a new date
and is bumped when the date is unchanged, so every re-pin gets a new archive
name and the package workflow rebuilds it.
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RECIPES = ["dpm-recipes", "dpm-repo"]
REPO = "mrdevmohamed/faseela"
ZERO = "0" * 64


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def recipe_path(name):
    hits = sorted((ROOT / "recipes").glob(f"*/{name}/recipe.toml"))
    if len(hits) != 1:
        sys.exit(f"pin-recipes-source: expected one recipe named {name}, found {len(hits)}")
    return hits[0]


def sub1(text, pattern, repl, what, path):
    new, n = re.subn(pattern, lambda m: repl, text, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"pin-recipes-source: no `{what}` line in {path}")
    return new


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("commit", nargs="?", help="full 40-hex commit sha (default: git HEAD)")
    ap.add_argument("--no-fill", action="store_true", help="do not download and hash the tarball")
    a = ap.parse_args()

    commit = (a.commit or git("rev-parse", "HEAD")).lower()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        sys.exit("pin-recipes-source: the commit must be a full 40-character sha")
    try:
        version = git("show", "-s", "--format=%cd", "--date=format:%Y.%m.%d", commit)
    except subprocess.CalledProcessError:
        version = time.strftime("%Y.%m.%d", time.gmtime())
        print(f"commit {commit[:12]} is not in the local clone - using today's date {version}")

    for name in RECIPES:
        p = recipe_path(name)
        t = p.read_text(encoding="utf-8")
        old_ver = re.search(r'(?m)^version = "([^"]*)"', t).group(1)
        old_rel = int(re.search(r'(?m)^rel = (\d+)', t).group(1))
        rel = old_rel + 1 if old_ver == version else 1
        t = sub1(t, r'^version = ".*"$', f'version = "{version}"', "version", p)
        t = sub1(t, r'^rel = \d+$', f"rel = {rel}", "rel", p)
        t = sub1(t, r'^source = ".*"$',
                 f'source = "https://github.com/{REPO}/archive/{commit}.tar.gz"', "source", p)
        t = sub1(t, r'^source_dir = ".*"$', f'source_dir = "faseela-{commit}"', "source_dir", p)
        t = sub1(t, r'^sha256 = ".*"$', f'sha256 = "{ZERO}"', "sha256", p)
        p.write_text(t, encoding="utf-8")
        print(f"{name}: version {version} rel {rel} -> {commit[:12]}")

    if a.no_fill:
        print("sha256 left as the placeholder; run scripts/fill-sha256.py -r dpm-recipes -r dpm-repo")
        return
    cmd = [sys.executable, str(ROOT / "scripts" / "fill-sha256.py")]
    for name in RECIPES:
        cmd += ["-r", name]
    sys.exit(subprocess.call(cmd))


if __name__ == "__main__":
    main()
