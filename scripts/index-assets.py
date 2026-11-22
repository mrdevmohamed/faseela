#!/usr/bin/env python3
"""scripts/index-assets.py — read the package list of a schema-v3+ repository index.

    index-assets.py INDEX.toml names           file name of every package archive
    index-assets.py INDEX.toml urls FILE...    "FILE<TAB>download-url" for each FILE

A signed repository index (release `stable-v5` of faseela-repo) lists its
archives as [[package]] entries (`file`, `download_url`); the release itself
holds only index files and the immutable packages-v5-NNNN storage assets, so
"which archives exist" is answered by the index, not by a release's asset list.
The ISO workflow uses `names` for check-flavor-packages.py and `urls` to
download the archives of the closure check. The signature is NOT checked here
(`nawa` verifies it when installing); this is a planning/diagnostic read.
"""
import sys
import tomllib
from pathlib import Path


def load(path: str) -> list[dict]:
    try:
        doc = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise SystemExit(f"index-assets: cannot read {path}: {exc}")
    entries = doc.get("package")
    if not isinstance(entries, list) or not entries:
        raise SystemExit(f"index-assets: {path} lists no packages")
    out = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
            raise SystemExit(f"index-assets: {path} has a package entry without a file name")
        out.append(entry)
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[2] not in ("names", "urls"):
        print(__doc__, file=sys.stderr)
        return 2
    entries = load(argv[1])
    if argv[2] == "names":
        for entry in entries:
            print(entry["file"])
        return 0
    by_file = {e["file"]: e for e in entries}
    status = 0
    for name in argv[3:]:
        entry = by_file.get(name)
        url = entry.get("download_url") if entry else None
        if not isinstance(url, str) or not url.startswith("https://"):
            print(f"index-assets: {name} has no https download_url in the index", file=sys.stderr)
            status = 1
            continue
        print(f"{name}\t{url}")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
