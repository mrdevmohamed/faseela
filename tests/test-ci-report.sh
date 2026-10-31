#!/usr/bin/env bash
# tests/test-ci-report.sh — scripts/ci-report.py against fixture logs and
# fixture API answers (no network, no gh).
set -u
REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
R="python3 -I $REPO/scripts/ci-report.py"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# ---- excerpt ----------------------------------------------------------------
cat > "$W/bad.log" <<'LOG'
2026-10-31T03:55:14.7049887Z == stage3: verifying self-hosting
2026-10-31T03:56:17.2412414Z nawa: lint: warning: usr/bin/x: not a parseable ELF — skipped
2026-10-31T03:56:17.2412414Z gcc -Werror -Wno-error=foo -c a.c
2026-10-31T03:56:17.2412414Z final-root: ERROR: usr/bin/foo needs libbar.so.1, which is not in the root
2026-10-31T03:56:52.7425732Z build-all: FAILED during 'stage3' (exit 1)
LOG
printf '== all fine\nnawa: lint: checked 3 ELF file(s)\n' > "$W/ok.log"
out=$($R excerpt "$W/bad.log" --title core)
check "failed stage is named"            "grep -q 'failed during \`stage3\`' <<<\"\$out\""
check "error line is shown, no stamp"    "grep -q '^final-root: ERROR: usr/bin/foo needs libbar.so.1' <<<\"\$out\""
check "warnings and -Werror are noise"   "! grep -q 'parseable ELF' <(sed -n '/^\`\`\`$/,/^\`\`\`$/p' <<<\"\$out\" | head -4) && ! grep -q 'Werror' <<<\"\$(sed -n '1,/<details>/p' <<<\"\$out\")\""
check "tail is collapsed"                "grep -q '<details>' <<<\"\$out\""
out=$($R excerpt "$W/ok.log" --title core)
check "clean log says so in one line"    "grep -q '✅ core: no failure' <<<\"\$out\" && [[ \$(wc -l <<<\"\$out\") -le 2 ]]"
out=$($R excerpt "$W/missing.log" --title core)
check "missing log is a warning"         "grep -q '⚠️ core: no log' <<<\"\$out\""

# ---- report -----------------------------------------------------------------
cat > "$W/jobs.json" <<'J'
{"jobs":[
 {"name":"recipes revision","conclusion":"success","status":"completed","started_at":"2026-10-31T01:00:00Z","completed_at":"2026-10-31T01:00:20Z","html_url":"https://x/job/1","steps":[]},
 {"name":"core (seed → stage3 → rootfs)","conclusion":"failure","status":"completed","started_at":"2026-10-31T01:01:00Z","completed_at":"2026-10-31T03:57:00Z","html_url":"https://x/job/2",
  "steps":[{"name":"Checkout","number":2,"conclusion":"success"},{"name":"Build the core","number":14,"conclusion":"failure"}]},
 {"name":"iso-gui","conclusion":"skipped","status":"completed","started_at":null,"completed_at":null,"html_url":"https://x/job/3","steps":[]},
 {"name":"run report","conclusion":null,"status":"in_progress","started_at":"2026-10-31T03:58:00Z","completed_at":null,"steps":[]}
]}
J
echo '{"artifacts":[{"name":"build-logs-core","size_in_bytes":2411724,"expired":false},{"name":"old","size_in_bytes":1,"expired":true}]}' > "$W/arts.json"
echo '{"run_started_at":"2026-10-31T01:00:00Z"}' > "$W/run.json"
echo '{"core":{"result":"failure"},"plan":{"result":"success"}}' > "$W/needs-bad.json"
echo '{"core":{"result":"success"},"build":{"result":"skipped"}}' > "$W/needs-ok.json"
mkdir "$W/extra"; $R excerpt "$W/bad.log" --title core > "$W/extra/core.md"
rep() { GITHUB_WORKFLOW="Build ISO (CD)" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=9 GITHUB_EVENT_NAME=workflow_dispatch \
        GITHUB_REF_NAME=master GITHUB_SHA=0123456789abcdef $R report --jobs-json "$W/jobs.json" \
        --artifacts-json "$W/arts.json" --run-json "$W/run.json" "$@"; }
out=$(rep --needs-json "$W/needs-bad.json" --extra "$W/extra" --fact "Recipes=abc123")
check "failure verdict in the title"     "head -1 <<<\"\$out\" | grep -q '❌ Build ISO (CD): Build failed'"
check "own job is left out"              "! grep -q 'run report' <<<\"\$out\""
check "durations are humanised"          "grep -q '2h 56m' <<<\"\$out\""
check "failed step is named with link"   "grep -q 'step \*Build the core\* (\[log\](https://x/job/2#step:14:1))' <<<\"\$out\""
check "excerpt is included"              "grep -q 'final-root: ERROR: usr/bin/foo' <<<\"\$out\""
check "facts are listed"                 "grep -q '| \*\*Recipes\*\* | abc123 |' <<<\"\$out\""
check "expired artifacts are hidden"     "grep -q 'build-logs-core.*2.3 MiB' <<<\"\$out\" && ! grep -q '\`old\`' <<<\"\$out\""
out=$(rep --needs-json "$W/needs-ok.json" --extra "$W/extra")
check "success verdict (skipped is ok)"  "head -1 <<<\"\$out\" | grep -q '✅ Build ISO (CD): Build succeeded'"
check "excerpts hidden on success"       "! grep -q 'Failure details' <<<\"\$out\""
out=$(GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=9 $R report --jobs-json "$W/none.json" --artifacts-json "$W/arts.json" --run-json "$W/run.json")
check "missing data degrades, no crash"  "grep -q 'report is incomplete' <<<\"\$out\""

echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
