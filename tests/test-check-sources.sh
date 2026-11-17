#!/usr/bin/env bash
# scripts/check-sources.py: GNU mirror fallback, retry with back-off, and the
# exit code, against a local HTTP server (no internet needed).
set -u
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

T="$(mktemp -d)"; trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/srv.py" <<'PY'
import http.server, sys
hits = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        n = hits[self.path] = hits.get(self.path, 0) + 1
        if self.path == "/flaky" and n < 3:      # 503 twice, then fine
            self.send_response(503)
        elif self.path in ("/ok", "/ok2", "/flaky"):
            self.send_response(206)
        else:
            self.send_response(404)
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$((20000 + RANDOM % 20000))
python3 "$T/srv.py" "$PORT" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$PORT/ok" && break; sleep 0.3; done
B="http://127.0.0.1:$PORT"

mk() { # name, source, [mirrors toml]
    mkdir -p "$T/r/base/$1"
    printf '[package]\nname = "%s"\nversion = "1"\nsource = "%s"\n%s\n' "$1" "$2" "${3:-}" > "$T/r/base/$1/recipe.toml"
}

mk_multi() { # name, first URL, second URL
    mkdir -p "$T/r/base/$1"
    cat > "$T/r/base/$1/recipe.toml" <<EOF
[package]
name = "$1"
version = "1"
source = "local:/nawa-schema-2-requires-a-newer-nawa"

[[package.sources]]
name = "main"
url = "$2"
sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[[package.sources]]
name = "patches"
url = "$3"
sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
EOF
}
run() { CHECK_SOURCES_DELAY=0.1 python3 -I scripts/check-sources.py "$T/r" "$@" 2>&1; }

mk_at() { # category, name, source
    mkdir -p "$T/r/$1/$2"
    printf '[package]\nname = "%s"\nversion = "1"\nsource = "%s"\n' "$2" "$3" > "$T/r/$1/$2/recipe.toml"
}

mk ok "$B/ok"
mk flaky "$B/flaky"
mk viamirror "http://127.0.0.1:1/dead" "mirrors = [\"$B/ok\"]"
out=$(run); rc=$?
check "reachable / flaky (retried) / mirror-only recipes pass"   "[[ $rc -eq 0 ]]"
check "mirror-only recipe is a warning, not an error"            "grep -q 'warning::viamirror' <<< \"\$out\" && ! grep -q 'error::' <<< \"\$out\""
check "summary counts it"                                        "grep -q '3 recipes: 0 unreachable, 1 on mirror only' <<< \"\$out\""

mk dead "$B/missing"
out=$(run); rc=$?
check "a recipe with no answering url fails the run"             "[[ $rc -eq 1 ]] && grep -q 'error::dead: no source url reachable' <<< \"\$out\""

# GNU urls are expanded to the same mirrors nawa tries
exp=$(python3 -I - <<'PY'
import importlib.util
sp = importlib.util.spec_from_file_location("cs", "scripts/check-sources.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
c = m.candidates("https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz", ["https://x.example/m.tar.xz"])
print(len(c), c[1].split("/")[2], c[-1].split("/")[2])
PY
)
check "GNU url expands to alternates then the recipe mirrors"    "[[ \"\$exp\" == '5 ftpmirror.gnu.org x.example' ]]"
python3 -I scripts/check-sources.py --dry-run "$T/r" >/dev/null
check "--dry-run needs no network"                               "[[ $? -eq 0 ]]"

# Multi-source recipes use package.sources; package.source is only a
# fail-closed compatibility marker for older Nawa and must not be fetched.
rm -rf "$T/r"; mkdir -p "$T/r"
mk_multi multi "$B/ok" "$B/ok2"
out=$(run); rc=$?
check "schema-2 marker is ignored and every external source is checked" \
    "[[ $rc -eq 0 ]] && grep -q '2 external artifacts' <<< \"\$(CHECK_SOURCES_DELAY=0.1 python3 -I scripts/check-sources.py --dry-run \"$T/r\")\""

# All declared artifacts are required: a reachable first source cannot hide
# a missing second source.
rm -rf "$T/r"; mkdir -p "$T/r"
mk_multi multi "$B/ok" "$B/missing"
out=$(run); rc=$?
check "a missing secondary source fails the recipe" \
    "[[ $rc -eq 1 ]] && grep -q 'multi: no source url reachable' <<< \"\$out\" && grep -q 'patches:' <<< \"\$out\""

# Meta recipes and legacy local sources have no network URL. They must be
# skipped cleanly rather than passing an empty string into urllib.
rm -rf "$T/r"; mkdir -p "$T/r"
mk meta ""
mk localcopy "local:/path/to/local/source"
out=$(run); rc=$?
check "empty and local-only sources are skipped without URL exceptions" \
    "[[ $rc -eq 0 ]] && ! grep -q 'ValueError' <<< \"\$out\""

# Preflight can be restricted to the actual dependency-closed build set.
rm -rf "$T/r"; mkdir -p "$T/r"
mk wanted "$B/ok"
mk_at gui gui_only "$B/missing"
printf 'wanted\n' > "$T/packages"
out=$(run --packages-file "$T/packages"); rc=$?
check "package scope ignores unrelated GUI recipes" "[[ $rc -eq 0 ]] && grep -q 'checked 1 recipes: 0 unreachable, 0 on mirror only' <<< \"\$out\" && ! grep -q 'gui_only' <<< \"\$out\""

printf 'wanted\ngui_only\n' > "$T/packages"
out=$(run --packages-file "$T/packages"); rc=$?
check "a selected GUI recipe is still checked and can fail" "[[ $rc -eq 1 ]] && grep -q 'gui_only: no source url reachable' <<< \"\$out\""

printf 'not-in-recipes\n' > "$T/packages"
out=$(run --packages-file "$T/packages"); rc=$?
check "a requested package without a recipe fails clearly" "[[ $rc -eq 1 ]] && grep -q 'not-in-recipes: requested package has no recipe' <<< \"\$out\""

echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
