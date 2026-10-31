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
        elif self.path in ("/ok", "/flaky"):
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
run() { CHECK_SOURCES_DELAY=0.1 python3 -I scripts/check-sources.py "$T/r" 2>&1; }

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

echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
