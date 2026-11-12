#!/usr/bin/env bash
# Verify dynamic release-flavor discovery against a small synthetic recipe tree.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts" "$W/recipes/base/pkg"
cp "$REPO/scripts/plan-flavors.py" "$REPO/scripts/flavor.py" "$W/scripts/"
cat > "$W/recipes/base/pkg/recipe.toml" <<'T'
[package]
name = "pkg"
version = "1.0"
rel = 1
T
cat > "$W/flavors.toml" <<'T'
[flavor.bootstrap]
include = ["pkg"]
closure = "build"

[flavor.seed]
extends = ["bootstrap"]

[flavor.iso-nogui]
include = ["pkg"]

[flavor.iso-gui]
extends = ["iso-nogui"]

[flavor.iso-xfce]
extends = ["iso-nogui"]

[flavor.rootfs-min]
include = ["pkg"]

[flavor.developer-base]
include = ["pkg"]
T

plan() {
  python3 -I "$W/scripts/plan-flavors.py" --flavors "$W/flavors.toml" \
    --recipes "$W/recipes" --selection "$1"
}

plan all > "$W/all.json"
python3 - "$W/all.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
items = p["matrix"]["include"]
names = [x["variant"] for x in items]
assert names == ["iso-gui", "iso-nogui", "iso-xfce", "rootfs-min"], names
assert p["has_iso"] is True
assert p["has_variants"] is True
assert p["has_rootfs_min"] is True
by_name = {x["variant"]: x for x in items}
assert by_name["iso-xfce"]["iso"] == "faseela-xfce-x86_64.iso"
assert by_name["iso-xfce"]["vol"] == "FASEELA_XFCE"
assert by_name["iso-nogui"]["iso"] == "faseela-x86_64.iso"
assert by_name["iso-gui"]["iso"] == "faseela-gui-x86_64.iso"
assert by_name["rootfs-min"]["rootfs"] == "faseela-x86_64-rootfs-min.tar.zst"
assert [x["variant"] for x in p["isos"]["include"]] == [
    "iso-gui", "iso-nogui", "iso-xfce"
]
PY

plan "iso-xfce, developer-base" > "$W/selected.json"
python3 - "$W/selected.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))["matrix"]["include"]
assert [x["variant"] for x in items] == ["iso-xfce", "developer-base"]
assert items[0]["kind"] == "iso"
assert items[1]["kind"] == "rootfs"
assert items[1]["rootfs"] == "faseela-developer-base-x86_64-rootfs.tar.zst"
PY

plan core > "$W/core.json"
python3 - "$W/core.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["matrix"]["include"] == []
assert p["isos"]["include"] == []
assert p["has_iso"] is False
assert p["has_variants"] is False
assert p["has_rootfs_min"] is False
PY

if plan does-not-exist > /dev/null 2>&1; then
  echo "unknown flavor was accepted" >&2
  exit 1
fi
if plan bootstrap > /dev/null 2>&1; then
  echo "internal bootstrap flavor was accepted as an image" >&2
  exit 1
fi
if plan "all iso-xfce" > /dev/null 2>&1; then
  echo "'all' mixed with explicit selections was accepted" >&2
  exit 1
fi

echo "test-plan-flavors: ok"
