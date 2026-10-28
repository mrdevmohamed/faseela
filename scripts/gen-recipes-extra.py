#!/usr/bin/env python3
"""Render recipe.toml files for the extra/ set.

Usage:
    python3 gen-recipes-extra.py          # all 47
    python3 gen-recipes-extra.py extra1   # dev + archive tools only
    python3 gen-recipes-extra.py extra2   # networking + editors only
    python3 gen-recipes-extra.py extra3   # misc + libs + hw only
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from recipe_data_extra import EXTRA

# the repo's recipes/ tree, derived from this script's location — a
# hard-coded absolute path silently wrote the recipes OUTSIDE the repo
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "recipes")
ROOT = os.path.normpath(ROOT)


def toml_str(s):
    """Escape a string as a TOML basic string (backslash and quotes first)."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_str_list(items):
    return "[" + ", ".join(toml_str(i) for i in items) + "]"


def render(p):
    out = []
    if p.get("comment"):
        out.append(f"# {p['comment']}")
    out.append(f"# extra recipe: {p['summary']}")
    out.append("[package]")
    out.append(f'name = {toml_str(p["name"])}')
    out.append(f'version = {toml_str(p["ver"])}')
    out.append("rel = 1")
    out.append('arch = ["x86_64"]')
    out.append(f'summary = {toml_str(p["summary"])}')
    out.append(f'license = {toml_str_list(p["license"])}')
    out.append(f'source = {toml_str(p["url"])}')
    out.append(f'sha256 = {toml_str(p["sha"])}')
    if p.get("sdir"):
        out.append(f'source_dir = {toml_str(p["sdir"])}')
    out.append("")
    out.append("[depends]")
    out.append(f'build = {toml_str_list(p.get("bdeps", []))}')
    out.append(f'run = {toml_str_list(p.get("rdeps", []))}')
    out.append("")
    out.append("[build]")
    for key in ("prepare", "configure", "compile", "install"):
        val = p.get(key, "")
        if not val:
            continue
        if "\n" in val:
            out.append(f'{key} = """')
            out.append(val)
            out.append('"""')
        else:
            out.append(f'{key} = {toml_str(val)}')
    if p.get("hook"):
        out.append("")
        out.append("[hooks]")
        out.append('post_install = """')
        out.append(p["hook"])
        out.append('"""')
    out.append("")
    return "\n".join(out)


def main():
    wanted = sys.argv[1] if len(sys.argv) > 1 else None
    written = 0
    for p in EXTRA:
        if wanted and p["sub"] != wanted:
            continue
        d = os.path.join(ROOT, "extra", p["name"])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "recipe.toml"), "w") as f:
            f.write(render(p))
        written += 1
    print(f"written {written} extra recipes under {ROOT}/extra")


if __name__ == "__main__":
    main()
