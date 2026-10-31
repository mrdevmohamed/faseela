#!/usr/bin/env bash
# tests/run-all.sh — run every test script and finish with one summary table.
# `make test` calls this; CI runs the same scripts as separate steps instead,
# so each one is its own line in the Actions UI.
set -u
cd "$(dirname "$0")/.." || exit 2
names=(); codes=(); secs=()
for t in tests/test-*.sh tests/validate-install.sh; do
    [[ -f "$t" ]] || continue
    printf '\n\033[1m==> %s\033[0m\n' "$t"
    start=$SECONDS
    bash "$t"; rc=$?
    names+=("$t"); codes+=("$rc"); secs+=("$((SECONDS - start))")
done
fail=0
printf '\n%-40s %-6s %s\n' "test" "result" "time"
printf '%-40s %-6s %s\n' "----" "------" "----"
for i in "${!names[@]}"; do
    if [[ ${codes[$i]} -eq 0 ]]; then r="PASS"; else r="FAIL"; fail=$((fail + 1)); fi
    printf '%-40s %-6s %ss\n' "${names[$i]#tests/}" "$r" "${secs[$i]}"
done
printf '\n%d of %d test scripts passed\n' "$(( ${#names[@]} - fail ))" "${#names[@]}"
[[ $fail -eq 0 ]]
