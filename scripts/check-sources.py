#!/usr/bin/env python3
"""Fail fast when a recipe's external source artifacts cannot be downloaded.

Supports both legacy package.source/package.mirrors and the multi-source
[[package.sources]] schema. New-schema recipes use a local: compatibility
marker in package.source; that marker is NOT a downloadable source. Every
declared external artifact is required, while its mirrors are alternatives.

Probes the first byte only. A flaky primary URL is a warning when a mirror
answers; a recipe fails when any required artifact has no reachable URL.
"""
import argparse
import glob
import os
import sys
import time
import tomllib
import threading
import urllib.request
import urllib.error
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlsplit

# Keep in step with nawa's src/fetch.rs candidate_urls.
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
SCHEMA_MARKER = "local:/nawa-schema-2-requires-a-newer-nawa"


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
    """Return (package name, [(artifact label, candidate URLs), ...])."""
    with open(path, "rb") as stream:
        package = tomllib.load(stream)["package"]

    name = package.get("name")
    version = str(package.get("version", ""))
    rel = str(package.get("rel", 1))
    arches = package.get("arch", [])
    arch = arches[0] if isinstance(arches, list) and arches else "x86_64"

    def expand(value):
        for key, replacement in (
            ("%{name}", str(name)),
            ("%{version}", version),
            ("%{rel}", rel),
            ("%{arch}", str(arch)),
        ):
            value = value.replace(key, replacement)
        return value

    def group(label, primary, mirrors=()):
        # An absent/blank URL is represented explicitly. It must not reach
        # urllib, which raises ValueError for an empty URL instead of a
        # normal network error.
        if not isinstance(primary, str) or not primary.strip():
            return label, []
        primary = expand(primary.strip())
        if primary.startswith("local:"):
            return label, []
        extras = [
            expand(m.strip())
            for m in mirrors
            if isinstance(m, str) and m.strip()
        ] if isinstance(mirrors, list) else []
        return label, candidates(primary, extras)

    # New-schema recipes may keep SCHEMA_MARKER in package.source solely so
    # older Nawa builds fail closed. The actual URLs live in package.sources.
    if "sources" in package:
        declared = package.get("sources")
        if not isinstance(declared, list) or not declared:
            return name, [("package.sources", [])]
        groups = []
        for index, source in enumerate(declared, start=1):
            if not isinstance(source, dict):
                groups.append((f"source#{index}", []))
                continue
            label = source.get("name")
            if not isinstance(label, str) or not label.strip():
                label = f"source#{index}"
            groups.append(group(label, source.get("url"), source.get("mirrors", [])))
        return name, groups

    # Legacy source-less/meta packages and local host-copy sources have no
    # external URL to probe. Never try a schema compatibility marker as URL.
    source = package.get("source")
    if not isinstance(source, str) or not source.strip() or source.startswith("local:"):
        return name, []
    return name, [group("source", source, package.get("mirrors", []))]


# At most this many concurrent probes per host. Too many parallel requests
# to one GNU mirror caused transient failures in the past.
HOST_LIMIT = 4
_hosts = defaultdict(lambda: threading.BoundedSemaphore(HOST_LIMIT))
_hosts_lock = threading.Lock()


def probe(url, tries=3, delay=float(os.environ.get("CHECK_SOURCES_DELAY", "3"))):
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return False, "invalid URL"
    with _hosts_lock:
        sem = _hosts[parsed.netloc]
    with sem:
        return _probe(url, tries, delay)


def _probe(url, tries, delay):
    last = ""
    for i in range(tries):
        if i:
            time.sleep(delay * i)  # back off: 3 s, then 6 s
        req = urllib.request.Request(
            url,
            headers={"Range": "bytes=0-0", "User-Agent": "faseela-check-sources"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return True, str(response.status)
        except urllib.error.HTTPError as exc:
            last = str(exc.code)
            if exc.code in (404, 403, 410):
                break
        except Exception as exc:
            last = type(exc).__name__
    return False, last


def check(item):
    name, groups = item
    outcomes = []
    for label, choices in groups:
        if not choices:
            outcomes.append((label, "", False, "missing or non-downloadable URL", False))
            continue
        tried = []
        for index, url in enumerate(choices):
            ok, detail = probe(url)
            tried.append((url, ok, detail))
            if ok:
                outcomes.append((label, url, True, detail, index > 0))
                break
        else:
            outcomes.append((label, tried[-1][0], False, tried[-1][2], False))
    return name, outcomes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("recipes", nargs="?", default="recipes")
    parser.add_argument("--jobs", type=int, default=16)
    parser.add_argument(
        "--packages-file",
        help="check only package names listed in this file (one name per line)",
    )
    parser.add_argument("--dry-run", action="store_true", help="only parse recipes, no network")
    args = parser.parse_args()

    requested = None
    if args.packages_file:
        with open(args.packages_file, encoding="utf-8") as stream:
            requested = {
                line.split("#", 1)[0].strip()
                for line in stream
                if line.split("#", 1)[0].strip()
            }
        if not requested:
            parser.error("--packages-file contains no package names")

    items = []
    found = set()
    for recipe_path in sorted(glob.glob(os.path.join(args.recipes, "*", "*", "recipe.toml"))):
        name, groups = urls(recipe_path)
        if not name:
            continue
        found.add(name)
        if requested is None or name in requested:
            items.append((name, groups))

    missing = sorted(requested - found) if requested is not None else []
    if missing:
        for name in missing:
            print(f"::error::{name}: requested package has no recipe")
        return 1

    if args.dry_run:
        artifact_count = sum(len(groups) for _, groups in items)
        url_count = sum(len(choices) for _, groups in items for _, choices in groups)
        print(f"{len(items)} recipes, {artifact_count} external artifacts, {url_count} candidate urls")
        return 0

    bad = warn = 0
    with ThreadPoolExecutor(args.jobs) as executor:
        for name, outcomes in executor.map(check, items):
            failed = [o for o in outcomes if not o[2]]
            mirrored = [o for o in outcomes if o[2] and o[4]]
            if failed:
                bad += 1
                details = []
                for label, url, _ok, status, _mirror in failed:
                    if url:
                        details.append(f"{label}: {url} ({status})")
                    else:
                        details.append(f"{label}: {status}")
                print(f"::error::{name}: no source url reachable: " + ", ".join(details))
            elif mirrored:
                warn += 1
                details = ", ".join(f"{label}: primary url down, mirror ok: {url}"
                                    for label, url, _ok, _status, _mirror in mirrored)
                print(f"::warning::{name}: {details}")

    print(f"checked {len(items)} recipes: {bad} unreachable, {warn} on mirror only")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
