#!/usr/bin/env bash
# bootstrap/build-all.sh — the one-command pipeline: empty directory -> bootable ISO.
#
# Wraps the five stage scripts with the orchestration they individually lack:
#
#   * stamp-based resume — after a failure, re-run the same command and the
#     stages that already finished are skipped automatically.  The state
#     directory lives OUTSIDE the target root, so it never leaks into the
#     squashfs/ISO.
#   * one timestamped log per invocation + per-stage timing recorded in
#     <state>/meta
#   * pre-flight checks (root, ~10 GB disk, host tools, network) BEFORE any
#     stage starts, so a missing xorriso cannot waste three hours of gcc
#   * --from-stage to force a restart point, --fresh to redo everything,
#     --wipe to also delete a previous target, --dry-run to preview,
#     --list-stages to inspect progress
#
# Pipeline (see README.md for what each stage does):
#   seed    seed/build-seed.sh   assemble the prebuilt toolchain
#   stage1  stage1.sh            unpack seed, chroot, verify toolchain
#   stage2  stage2.sh            DPM builds the full recipe graph
#   stage3  stage3.sh            self-hosting rebuild (seed removed)
#   iso     mkiso.sh             initramfs + squashfs + grub -> bootable ISO
#
# Usage:
#   sudo ./build-all.sh /mnt/mydistro
#   sudo ./build-all.sh --isolation sandbox --stage3-world /mnt/mydistro
#   sudo ./build-all.sh --no-iso /mnt/mydistro                  # stop after stage3
#   ./build-all.sh --from-stage iso /mnt/mydistro out/my.iso     # stage4: non-root
#   ./build-all.sh --list-stages /mnt/mydistro
#   ./build-all.sh --dry-run /mnt/mydistro
#
# Env knobs (same as the underlying stage scripts):
#   DPM_JOBS=<n>  WITH_GUI=1  STAGE3_WORLD=1  VOL_ID=<name>  SQUASH_COMP=gzip|xz|zstd
set -Eeuo pipefail

ORIG_ARGS=("$@")   # captured before the arg loop shifts them — used by the
                   # failure trap to print a copy-paste resume command

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PROG=build-all
MIN_FREE_KB=$((10 * 1024 * 1024))   # ~10 GB, per bootstrap/README.md

STAGE_IDS=(seed stage1 stage2 stage3 iso)
declare -A STAGE_DESC=(
    [seed]="assemble the prebuilt toolchain (seed.tar.zst)"
    [stage1]="unpack seed, mount, chroot, verify toolchain"
    [stage2]="DPM builds the full recipe graph"
    [stage3]="self-hosting rebuild (seed removed)"
    [iso]="initramfs + squashfs + grub -> bootable ISO"
)
SEED_TAR="$HERE/seed/seed.tar.zst"

usage() {
    cat <<EOF
$PROG — build the whole distribution: empty directory -> bootable ISO

Usage:
  sudo $PROG [options] TARGET [OUT_ISO]

Stages (resume is automatic: finished stages are skipped on re-run):
  seed    ${STAGE_DESC[seed]}
  stage1  ${STAGE_DESC[stage1]}
  stage2  ${STAGE_DESC[stage2]}
  stage3  ${STAGE_DESC[stage3]}
  iso     ${STAGE_DESC[iso]}

Options:
  --from-stage S    start at S: seed|0, 1, 2, 3, iso|4 (default: first incomplete)
  --fresh           clear completion stamps; every stage re-runs
  --wipe            delete TARGET entirely first (implies --fresh)
  --no-iso          stop after stage 3 (no ISO produced)
  --keep-mounts     do not unmount the chroot bind mounts at the end
  --stage3-world    STAGE3_WORLD=1 — rebuild EVERY package in stage 3
  --with-gui        WITH_GUI=1 — include recipes/gui in stage 2/3
  --isolation LVL   none|env|sandbox|closure (default none); closure applies
                    to stage 3 only, stage 2 then uses sandbox
  --jobs N          parallel jobs (default: nproc, else 4)
  --vol-id NAME     ISO volume id (default MYDISTRO)
  --squash-comp C   gzip|xz|zstd (default gzip)
  --out PATH        ISO output path (default <repo>/out/mydistro-x86_64.iso)
  --list-stages     show pipeline progress for TARGET and exit
  --dry-run         print what would run; execute and write nothing
  -h, --help        this text

Arguments:
  TARGET            the future distro root (e.g. /mnt/mydistro)
  OUT_ISO           ISO output path (positional alternative to --out)

Examples:
  sudo $PROG /mnt/mydistro
  sudo $PROG --isolation closure --stage3-world --with-gui /mnt/mydistro my.iso
  $PROG --from-stage iso /mnt/mydistro my.iso      # stage 4 runs fine as non-root
  $PROG --list-stages /mnt/mydistro
EOF
}

die() { echo "$PROG: error: $*" >&2; exit 2; }
note() { echo "$PROG: $*"; }

# ---------------------------------------------------------------- arguments --
TARGET="" OUT_ISO="" FROM_STAGE=""
OPT_FRESH=0 OPT_WIPE=0 OPT_NO_ISO=0 OPT_KEEP_MOUNTS=0
OPT_WORLD=0 OPT_GUI=0 OPT_LIST=0 OPT_DRYRUN=0
OPT_ISOLATION="${STAGE2_ISOLATION:-none}"
JOBS="${DPM_JOBS:-}"
VOL_ID="${VOL_ID:-MYDISTRO}"
SQUASH_COMP="${SQUASH_COMP:-gzip}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-stage)   [[ $# -ge 2 ]] || die "--from-stage needs a value"; FROM_STAGE="$2"; shift 2 ;;
        --fresh)        OPT_FRESH=1; shift ;;
        --wipe)         OPT_WIPE=1; OPT_FRESH=1; shift ;;
        --no-iso)       OPT_NO_ISO=1; shift ;;
        --keep-mounts)  OPT_KEEP_MOUNTS=1; shift ;;
        --stage3-world) OPT_WORLD=1; shift ;;
        --with-gui)     OPT_GUI=1; shift ;;
        --isolation)    [[ $# -ge 2 ]] || die "--isolation needs a value"; OPT_ISOLATION="$2"; shift 2 ;;
        --jobs)         [[ $# -ge 2 ]] || die "--jobs needs a value"; JOBS="$2"; shift 2 ;;
        --vol-id)       [[ $# -ge 2 ]] || die "--vol-id needs a value"; VOL_ID="$2"; shift 2 ;;
        --squash-comp)  [[ $# -ge 2 ]] || die "--squash-comp needs a value"; SQUASH_COMP="$2"; shift 2 ;;
        --out)          [[ $# -ge 2 ]] || die "--out needs a value"; OUT_ISO="$2"; shift 2 ;;
        --list-stages)  OPT_LIST=1; shift ;;
        --dry-run)      OPT_DRYRUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --*)            die "unknown option '$1' (see --help)" ;;
        *)
            if [[ -z $TARGET ]]; then TARGET="$1"
            elif [[ -z $OUT_ISO ]]; then OUT_ISO="$1"
            else die "unexpected extra argument '$1'"; fi
            shift ;;
    esac
done

[[ -n $TARGET ]] || { usage >&2; die "TARGET is required"; }
case "$OPT_ISOLATION" in
    none|env|sandbox|closure) ;;
    *) die "--isolation must be none|env|sandbox|closure (got '$OPT_ISOLATION')" ;;
esac
case "$SQUASH_COMP" in gzip|xz|zstd) ;; *) die "--squash-comp must be gzip|xz|zstd" ;; esac
if [[ -z $JOBS ]]; then JOBS="$(nproc 2>/dev/null || echo 4)"; fi
[[ $JOBS =~ ^[0-9]+$ && $JOBS -ge 1 ]] || die "--jobs must be a positive integer (got '$JOBS')"

TARGET="$(realpath -m -- "$TARGET")"
[[ $TARGET != "/" ]] || die "refusing to use / as the target"
STATE="$(dirname -- "$TARGET")/.$(basename -- "$TARGET").build"
STAMPS="$STATE/stamps"
LOGS="$STATE/logs"
META="$STATE/meta"
if [[ -n $OUT_ISO ]]; then OUT_ISO="$(realpath -m -- "$OUT_ISO")"
else OUT_ISO="$REPO/out/mydistro-x86_64.iso"; fi

if [[ $EUID -ne 0 && $OPT_LIST -eq 0 ]]; then
    note "WARNING: not root — only '--from-stage iso' (stage 4) can work without root"
fi

# ------------------------------------------------------------------- stamps --
stamp_file() { printf '%s/%s.done' "$STAMPS" "$1"; }
stage_done() { [[ -f "$(stamp_file "$1")" ]]; }

stage_done_or_adopted() {
    local s="$1"
    if stage_done "$s"; then return 0; fi
    # A seed tarball built by hand (or left behind by an earlier run whose
    # stamp was cleared) is adopted instead of re-downloading ~1 GB of
    # toolchain for nothing.  --fresh still forces a real rebuild: it sets
    # OPT_FRESH, which skips adoption below.
    if [[ $s == seed && -s $SEED_TAR && ${OPT_FRESH:-0} -eq 0 ]]; then return 0; fi
    return 1
}

stage_index() {  # accept seed|0..3|iso|4 -> index into STAGE_IDS
    case "$1" in
        seed|0) echo 0 ;;
        1)      echo 1 ;;
        2)      echo 2 ;;
        3)      echo 3 ;;
        iso|4)  echo 4 ;;
        *)      return 1 ;;
    esac
}

list_stages() {
    local i id status n=0
    echo "target: $TARGET"
    echo "state:  $STATE"
    echo
    printf '  %-8s %-50s %s\n' STAGE DESCRIPTION STATUS
    for i in "${!STAGE_IDS[@]}"; do
        id=${STAGE_IDS[$i]}
        if stage_done "$id"; then
            status="done $(stat -c %y "$(stamp_file "$id")" 2>/dev/null | cut -d. -f1)"
            n=$((n+1))
        elif stage_done_or_adopted "$id"; then
            status="done (adopted $(stat -c %y "$SEED_TAR" 2>/dev/null | cut -d. -f1))"
            n=$((n+1))
        elif [[ $id == iso && $OPT_NO_ISO -eq 1 ]]; then
            status="skipped (--no-iso)"
        else
            status="pending"
        fi
        printf '  %-8s %-50s %s\n' "$id" "${STAGE_DESC[$id]}" "$status"
    done
    echo
    echo "  $n/5 stages recorded as complete"
    if [[ -d $LOGS ]]; then
        echo "  logs:   $LOGS ($(ls -1 "$LOGS" 2>/dev/null | wc -l) file(s))"
    fi
    exit 0
}

# ------------------------------------------------------------------- checks --
preflight() {
    local need_root=0 parent probe i id have t missing=()
    for i in "${!STAGE_IDS[@]}"; do
        if (( i < START )); then continue; fi
        case ${STAGE_IDS[$i]} in stage1|stage2|stage3) need_root=1 ;; esac
    done
    if (( need_root )) && [[ $EUID -ne 0 ]]; then
        die "stages 1-3 need root; re-run with sudo, or use --from-stage iso for the non-root stage 4"
    fi

    # free space on the filesystem that will hold TARGET (walk up if the
    # parent does not exist yet — stage1 creates it)
    probe="$(dirname -- "$TARGET")"
    while [[ ! -d $probe && $probe != "/" ]]; do probe="$(dirname -- "$probe")"; done
    have=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {print $4}')
    if (( ${have:-0} < MIN_FREE_KB )); then
        die "only $(( ${have:-0} / 1024 / 1024 )) GB free on $probe — the build needs ~10 GB"
    fi

    # host tools for the stages that will actually run: fail BEFORE gcc burns
    # three hours, not after
    for i in "${!STAGE_IDS[@]}"; do
        if (( i < START )); then continue; fi
        id=${STAGE_IDS[$i]}
        case $id in
            seed)
                command -v curl >/dev/null || die "seed stage needs curl on the host"
                ;;
            iso)
                missing=()
                for t in mksquashfs grub-mkrescue gcc make; do
                    command -v "$t" >/dev/null || missing+=("$t")
                done
                if (( ${#missing[@]} > 0 )); then
                    die "iso stage misses host tool(s): ${missing[*]}
       Debian: apt install squashfs-tools grub-pc-bin grub-efi-amd64-bin xorriso mtools build-essential"
                fi
                ;;
        esac
    done

    if (( need_root )) && ! curl -sI -m 8 https://sh.rustup.rs >/dev/null 2>&1; then
        note "WARNING: https://sh.rustup.rs unreachable — the build downloads sources, it cannot run offline"
    fi
}

# ---------------------------------------------------------------- pipeline ---
CURRENT_STAGE="(pre-flight)"
LOG=""
trap 'on_exit $?' EXIT
on_exit() {
    local rc=$1
    if (( rc != 0 && rc != 2 )); then
        {
            echo
            echo "$PROG: FAILED during '$CURRENT_STAGE' (exit $rc)"
            [[ -n $LOG ]] && echo "$PROG: full log: $LOG"
            echo "$PROG: the target is KEPT for resume — fix the cause and re-run:"
            echo "$PROG:   $0 ${ORIG_ARGS[*]:-}"
            echo "$PROG: chroot mounts may be stale (dead or live) in $TARGET:"
            echo "$PROG:   verify/repair:  sudo $HERE/ensure-chroot-mounts.sh $TARGET"
            echo "$PROG:   tear down:      sudo $HERE/umount-chroot.sh $TARGET"
        } >&2
    fi
    # the log tee (this shell's stdout via exec> >()) needs EOF to drain;
    # close our end FIRST, then reap it — waiting while still holding the
    # pipe open would deadlock
    exec 1>&- 2>&- 2>/dev/null
    wait 2>/dev/null || true
}

# decide where the run starts
if [[ -n $FROM_STAGE ]]; then
    START="$(stage_index "$FROM_STAGE")" || die "--from-stage must be seed|0|1|2|3|iso|4 (got '$FROM_STAGE')"
else
    START=${#STAGE_IDS[@]}
    for i in "${!STAGE_IDS[@]}"; do
        if ! stage_done_or_adopted "${STAGE_IDS[$i]}"; then START=$i; break; fi
    done
fi
END=$(( ${#STAGE_IDS[@]} - 1 ))
if (( OPT_NO_ISO )); then END=$(( END - 1 )); fi

if (( OPT_WIPE )); then
    case "$TARGET" in
        "/"|"$REPO"|"$REPO/"|"$HOME"|"$HOME/"|"$(dirname -- "$REPO")")
            die "refusing to --wipe $TARGET" ;;
    esac
    if [[ -e $TARGET ]]; then
        if mountpoint -q "$TARGET"; then die "refusing to --wipe a mountpoint"; fi
        note "--wipe: deleting $TARGET"
        if (( ! OPT_DRYRUN )); then rm -rf -- "$TARGET"; fi
    fi
fi
if (( OPT_FRESH )) && [[ -d $STAMPS ]]; then
    note "--fresh: clearing stage stamps in $STAMPS"
    if (( ! OPT_DRYRUN )); then rm -rf -- "$STAMPS"; fi
fi
# forcing a start point invalidates that stage and everything after it
# ("start at stage 2" means stage 2 RUNS, stamps from stage 2 onward are stale)
if [[ -n $FROM_STAGE ]]; then
    for i in "${!STAGE_IDS[@]}"; do
        if (( i < START )); then continue; fi
        if [[ -f "$(stamp_file "${STAGE_IDS[$i]}")" ]]; then
            note "invalidating stamp: ${STAGE_IDS[$i]} (restarting at $FROM_STAGE)"
            if (( ! OPT_DRYRUN )); then rm -f "$(stamp_file "${STAGE_IDS[$i]}")"; fi
        fi
    done
fi

if (( OPT_LIST )); then list_stages; fi

# non-empty target with no recorded progress = probably not what the user wants
# (stage1 would unpack the seed over unrelated files)
if [[ -d $TARGET && -n "$(ls -A "$TARGET" 2>/dev/null)" && ! -d $STAMPS ]] \
   && (( ! OPT_WIPE && ! OPT_DRYRUN )); then
    die "TARGET $TARGET is not empty and has no build state
       - to replace its contents deliberately: re-run with --wipe
       - or pick a fresh directory"
fi
if (( START >= 1 && START <= 3 )) && ! stage_done stage1 && (( ! OPT_DRYRUN )); then
    note "NOTE: starting at stage $START with no stage-1 stamp — stage 2/3 now
      ensure the chroot mounts themselves (ensure-chroot-mounts.sh), but
      running stage 1 first is still recommended (it is idempotent)"
fi

if (( ! OPT_DRYRUN )); then
    preflight
fi

# pass the knobs down to the stage scripts (they read them from the env)
export DPM_JOBS="$JOBS"
export WITH_GUI="$OPT_GUI"
# stage 2 builds against the seed plus what it has built so far; `closure`
# needs the finished base-devel archive set, which exists only from stage 3 on
# (stage2-inner.sh rejects it). Use the strongest level stage 2 supports.
export STAGE2_ISOLATION="$OPT_ISOLATION"
if [[ $OPT_ISOLATION == closure ]]; then
    export STAGE2_ISOLATION=sandbox
    echo "$PROG: note: --isolation closure applies to stage 3; stage 2 uses sandbox"
fi
export STAGE3_ISOLATION="$OPT_ISOLATION"
export STAGE3_WORLD="$OPT_WORLD"
export VOL_ID SQUASH_COMP JOBS="$JOBS"

# logging (never in --dry-run: it must not touch anything)
if (( ! OPT_DRYRUN )); then
    mkdir -p "$LOGS"
    LOG="$LOGS/build-$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
fi

banner() {
    echo
    echo "===================================================================="
    echo "== $PROG: $1"
    echo "===================================================================="
}

fmt_el() {   # seconds -> 1h23m45s / 12m03s / 45s
    local s=$1
    if   (( s >= 3600 )); then printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
    elif (( s >= 60 ));   then printf '%dm%02ds' $((s/60)) $((s%60))
    else                       printf '%ds' "$s"
    fi
}

STAGE_ELAPSED=()
RAN_ISO=0
run_stage() {
    local id="$1" t0 t1 el
    CURRENT_STAGE="$id"
    banner "stage $id — ${STAGE_DESC[$id]}"
    t0=$(date +%s)
    case $id in
        seed)   CMD=(bash "$HERE/seed/build-seed.sh") ;;
        stage1) CMD=(bash "$HERE/stage1.sh" "$TARGET") ;;
        stage2) CMD=(bash "$HERE/stage2.sh" "$TARGET") ;;
        stage3) CMD=(bash "$HERE/stage3.sh" "$TARGET") ;;
        iso)    CMD=(bash "$HERE/mkiso.sh" "$TARGET" "$OUT_ISO") ;;
    esac
    if (( OPT_DRYRUN )); then
        echo "[dry-run] would run:  ${CMD[*]}"
        echo "[dry-run] would stamp: $(stamp_file "$id")"
    else
        "${CMD[@]}"
        mkdir -p "$STAMPS"
        date > "$(stamp_file "$id")"
        t1=$(date +%s); el=$((t1 - t0))
        printf '%s|%s|%ss|ok\n' "$id" "$(date -Is)" "$el" >> "$META"
        STAGE_ELAPSED+=("$(printf '%-8s took %s' "$id" "$(fmt_el "$el")")")
        echo "== $PROG: stage $id finished in $(fmt_el "$el")"
    fi
    [[ $id == iso ]] && RAN_ISO=1
    return 0
}

T_START=$(date +%s)
banner "mydistro build — target $TARGET"
echo "  jobs=$JOBS  isolation=$OPT_ISOLATION  gui=$OPT_GUI  stage3-world=$OPT_WORLD"
echo "  state=$STATE"
echo "  iso output: $OUT_ISO"
if (( OPT_DRYRUN )); then echo "  (dry run — nothing is executed or recorded)"; fi

# a hand-built seed adopted as done is worth saying out loud (the loop below
# starts past it, so this is the only place the notice is printed)
if (( ! OPT_DRYRUN )) && ! stage_done seed && stage_done_or_adopted seed; then
    note "seed: adopting existing $SEED_TAR (no stamp yet)"
fi

if (( START > END )); then
    note "nothing to run: every stage in range is already complete"
    if (( END == 4 )) && [[ -s $OUT_ISO ]]; then
        note "ISO from a previous run: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
    fi
fi

for (( i = START; i <= END; i++ )); do
    id=${STAGE_IDS[$i]}
    if (( OPT_DRYRUN )); then
        run_stage "$id"
    elif stage_done_or_adopted "$id"; then
        if [[ $id == seed ]] && ! stage_done seed; then
            note "seed: adopting existing $SEED_TAR (no stamp yet)"
        fi
        echo "-- $PROG: $id already done, skipping"
    else
        run_stage "$id"
    fi
done

# ---------------------------------------------------------------- epilogue ---
if (( ! OPT_DRYRUN )); then
    if (( ${#STAGE_ELAPSED[@]} > 0 )); then
        echo
        echo "== $PROG: stages completed this run:"
        printf '  %s\n' "${STAGE_ELAPSED[@]}"
    fi
    if (( RAN_ISO )); then
        if [[ -s $OUT_ISO ]]; then
            echo "== $PROG: ISO ready: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
        else
            echo "$PROG: ISO missing after stage 4: $OUT_ISO" >&2
            exit 1
        fi
    elif (( OPT_NO_ISO )); then
        note "stopped before the ISO (--no-iso); produce it later with:
      $0 --from-stage iso $TARGET $OUT_ISO"
    fi
    if [[ $EUID -eq 0 ]] && (( ! OPT_KEEP_MOUNTS )) && (( START <= 3 )); then
        if mountpoint -q "$TARGET/dev" || mountpoint -q "$TARGET/proc"; then
            banner "unmounting chroot bind mounts (--keep-mounts keeps them)"
            bash "$HERE/umount-chroot.sh" "$TARGET"
        fi
    fi
    echo
    echo "== $PROG: done in $(fmt_el $(( $(date +%s) - T_START )))"
    echo "== next steps:"
    echo "   - validate the built root:  scripts/validate-install.sh $TARGET"
    echo "   - boot the ISO in a VM:      $OUT_ISO"
    echo "   - install to disk (in live): sudo install.sh /dev/vda --yes"
fi
