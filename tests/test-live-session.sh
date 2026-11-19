#!/usr/bin/env bash
# test-live-session.sh — the live session's extras, without root or a VM:
#   * the initramfs /init is valid sh and knows Ventoy-style media (ISO as a file,
#     device-mapper device, exFAT/NTFS data partition)
#   * make_live_user (initramfs.sh) creates the passwordless `live` user, is idempotent
#     and respects the groups that exist
#   * the disk installer's cleanup (install.sh) removes every trace of it again
set -uo pipefail
REPO="${FASEELA_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/live-session-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

INITRAMFS="$REPO/bootstrap/initramfs.sh"
INSTALL="$REPO/bootstrap/install.sh"
sed -n '/^cat > "\$TREE\/init"/,/^INIT_EOF/p' "$INITRAMFS" | sed '1d;$d' > "$W/init"

# ---- A. /init -------------------------------------------------------------------
check "A1 /init is valid sh"                         "sh -n $W/init"
check "A2 initramfs.sh is valid bash"                "bash -n $INITRAMFS"
check "A3 exfat and ntfs3 are staged (build side)"   "grep -q '^MODLIST=.* exfat ntfs3 isofs\"' $INITRAMFS"
check "A4 exfat and ntfs3 are loaded (/init)"        "grep -q ' dm_mod ext4 exfat ntfs3 isofs\"' $INITRAMFS"
check "A5 device-mapper devices are scanned"         "grep -q '/dev/mapper/\*' $W/init && grep -q '/dev/dm-' $W/init"
check "A6 iso-scan/filename and findiso are read"    "grep -q 'iso-scan/filename=\*' $W/init && grep -q 'findiso=\*' $W/init"
check "A7 an ISO file is loop-mounted"               "grep -q 'mount -t iso9660 -o ro,loop' $W/init"
check "A8 the host partition is kept for the loop"   "grep -q 'mount --move /iso-host /newroot/media/iso-host' $W/init"
check "A9 /iso-host exists in the image tree"        "grep -q '\"\$TREE/iso-host\"' $INITRAMFS"
check "A10 the live user is made on live boots only" "[[ \$(grep -c '^make_live_user /newroot' $W/init) -eq 1 ]] && awk '/disk boot from/{d=NR} /^make_live_user \/newroot/{m=NR} END{exit !(m>d)}' $W/init"

# ---- B. make_live_user ----------------------------------------------------------
R="$W/root"; mkdir -p "$R/etc/skel" "$R/home"
printf 'root:x:0:0:r:/root:/bin/bash\n' > "$R/etc/passwd"
printf 'root:x:0:\nwheel:x:97:\nvideo:x:12:bob\naudio:x:11:\nseat:x:900:live\n' > "$R/etc/group"
printf 'root:*:19980:0:::::\n' > "$R/etc/shadow"
printf 'permit persist :wheel\n' > "$R/etc/doas.conf"; echo x > "$R/etc/skel/.bashrc"
sed -n '/^# >>> live-user/,/^# <<< live-user/p' "$INITRAMFS" | sed 's/chown -R 1000:1000 "\$r\/home\/live"/true/' > "$W/lu.sh"
RUN() { sh -c ". $W/lu.sh; make_live_user $R"; }
RUN; RUN    # twice: persistence re-applies it at every boot
check "B1 user live, uid 1000, bash, /home/live"      "[[ \$(grep -c '^live:x:1000:1000:' $R/etc/passwd) -eq 1 ]] && grep -q '^live:.*:/home/live:/bin/bash$' $R/etc/passwd"
check "B2 empty password for live and root"           "grep -q '^live::' $R/etc/shadow && grep -q '^root::' $R/etc/shadow"
check "B3 existing groups get live exactly once"      "grep -q '^wheel:x:97:live$' $R/etc/group && grep -q '^video:x:12:bob,live$' $R/etc/group && grep -q '^audio:x:11:live$' $R/etc/group && grep -q '^seat:x:900:live$' $R/etc/group"
check "B4 missing groups are not invented"            "! grep -q '^render:' $R/etc/group && ! grep -q '^input:' $R/etc/group"
check "B5 the private group exists once"              "[[ \$(grep -c '^live:x:1000:' $R/etc/group) -eq 1 ]]"
check "B6 home populated from /etc/skel"              "[[ -f $R/home/live/.bashrc ]]"
check "B7 doas rule added once"                       "[[ \$(grep -c '^permit nopass live$' $R/etc/doas.conf) -eq 1 ]] && grep -q 'persist :wheel' $R/etc/doas.conf"
check "B8 marker and login banner (once)"             "[[ -f $R/etc/faseela-live ]] && [[ \$(grep -c 'Faseela live session' $R/etc/issue) -eq 1 ]]"
check "B9 a root without doas.conf is fine"           "rm -f $R/etc/doas.conf && RUN && [[ ! -e $R/etc/doas.conf ]]"
printf 'permit persist :wheel\npermit nopass live\n' > "$R/etc/doas.conf"

# ---- C. the installer removes it ------------------------------------------------
sed -n '/^log "removing the live session/,/root:\*:/p' "$INSTALL" > "$W/strip.sh"
check "C1 the cleanup block was found"                "[[ \$(wc -l < $W/strip.sh) -ge 8 && \$(wc -l < $W/strip.sh) -le 14 ]] && ! grep -q mount $W/strip.sh"
check "C2 the cleanup runs before any user is made"   "awk '/removing the live session/{a=NR} /creating user/{b=NR} END{exit !(a&&b&&a<b)}' $INSTALL"
check "C3 /etc/faseela-live is not copied"            "grep -q -- '--exclude=/etc/faseela-live' $INSTALL"
mkdir -p "$R/home/live"; printf 'root:x:0:0:r:/root:/bin/bash\nlive:x:1000:1000:x:/home/live:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\n' > "$R/etc/passwd"
printf 'root::19980:0:::::\nlive::19980:0:99999:7:::\nbob:!:19980:0:::::\n' > "$R/etc/shadow"
RUNSTRIP() { MNT="$R" sh -c 'log(){ :; }; run(){ "$@"; }; . "$1"' _ "$W/strip.sh"; }
RUNSTRIP
check "C4 live is gone from passwd/shadow/group"      "! grep -q '^live:' $R/etc/passwd $R/etc/shadow $R/etc/group && grep -q '^bob:' $R/etc/passwd $R/etc/shadow"
check "C5 live is gone from every group member list"  "! grep -E '(:|,)live(,|\$)' $R/etc/group && grep -q '^video:x:12:bob$' $R/etc/group && grep -q '^wheel:x:97:\$' $R/etc/group"
check "C6 doas rule, banner and home removed"         "! grep -q 'nopass live' $R/etc/doas.conf && ! grep -q 'live session' $R/etc/issue && [[ ! -e $R/home/live ]]"
check "C7 root is locked until its password is set"   "grep -q '^root:\*:' $R/etc/shadow"
check "C8 the doas rule for wheel stays"              "grep -q 'persist :wheel' $R/etc/doas.conf"

# ---- D. opt-in installed-disk PID 1 probe -------------------------------------
check "D1 probe needs both explicit test flags" \
    "grep -Fq 'FASEELA_QEMU_BOOT_TEST requires NAWA_INSTALL_TEST=1' $INSTALL"
check "D2 the probe adds only a test serial console" \
    "grep -Fq 'console=tty0 console=ttyS0,115200' $INSTALL"
check "D3 the probe reads the real PID 1 comm" \
    "grep -Fq 'IFS= read -r init_comm < /proc/1/comm' $INSTALL && grep -Fq 'FASEELA_BOOT_ACCEPTANCE pid1=' $INSTALL"
check "D4 the probe checks the installed System Profile" \
    "grep -Fq '/usr/bin/nawa --root / system profile show' $INSTALL && grep -Fq 'FASEELA_BOOT_ACCEPTANCE system-profile=systemd' $INSTALL && ! grep -Eq 'grep -E.*system-profile.toml' $INSTALL"
check "D5 the probe is a multi-user systemd unit" \
    "grep -Fq 'faseela-boot-acceptance.service' $INSTALL && grep -Fq 'WantedBy=multi-user.target' $INSTALL"
check "D6 test mode keeps root locked and skips passwords" \
    "grep -Fq 'root remains locked; skipping interactive password setup' $INSTALL"
check "D7 ordinary installs still ask for the root password" \
    "grep -Fq '/usr/bin/passwd root' $INSTALL"

echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
