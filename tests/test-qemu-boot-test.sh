#!/usr/bin/env bash
# tests/test-qemu-boot-test.sh — qemu-boot-test.sh against a fake qemu:
# prompt appears -> pass; qemu dies -> fail; nothing happens -> timeout fail.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"; echo iso > "$W/fake.iso"
cat > "$W/bin/qemu-system-x86_64" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in file:*) f="${a#file:}" ;; esac; done
case "${FAKE_MODE:-ok}" in
    ok)   sleep 1; printf 'kernel...\nmydistro login: ' >> "$f"; sleep 30 ;;
    dead) sleep 1; echo oops >> "$f"; exit 3 ;;
    hang) sleep 60 ;;
esac
STUB
chmod +x "$W/bin/qemu-system-x86_64"
run() { PATH="$W/bin:$PATH" FAKE_MODE="$1" BOOT_TIMEOUT=6 bash "$REPO/scripts/qemu-boot-test.sh" "$W/fake.iso" "$W/out-$1" >"$W/$1.log" 2>&1; }
run ok   || { cat "$W/ok.log"; echo "FAIL: login prompt not recognised" >&2; exit 1; }
run dead && { echo "FAIL: dead qemu accepted" >&2; exit 1; }
run hang && { echo "FAIL: timeout accepted" >&2; exit 1; }
grep -q 'no login prompt within' "$W/hang.log" || { echo "FAIL: timeout message absent" >&2; exit 1; }
echo "test-qemu-boot-test: all checks passed"
