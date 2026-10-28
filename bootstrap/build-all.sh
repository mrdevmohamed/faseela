#!/usr/bin/env bash
# bootstrap/build-all.sh — the one-command pipeline: empty directory -> bootable ISO.
#
# Wraps the six stage scripts with the orchestration they individually lack:
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
#   rootfs  mkrootfs.sh          final root -> <name>-rootfs.tar.zst (+ .sha256)
#   iso     mkiso.sh             initramfs + squashfs + grub -> bootable ISO
#
# The rootfs is published next to the ISO AND is the seed of the next build:
#   sudo ./build-all.sh --seed-rootfs out/mydistro-x86_64-rootfs.tar.zst /mnt/mydistro
# replaces stage 0's Debian-based seed with the previous build's own system,
# so the distribution builds itself with its own toolchain (stage 1 unpacks
# the rootfs, seed-from-rootfs.sh adapts it).
#
# Usage:
#   sudo ./build-all.sh /mnt/mydistro
#   sudo ./build-all.sh --isolation sandbox --stage3-world /mnt/mydistro
#   sudo ./build-all.sh --no-iso /mnt/mydistro                  # no ISO (rootfs still built)
#   sudo ./build-all.sh --no-iso --no-rootfs /mnt/mydistro      # stop after stage3
#   ./build-all.sh --from-stage iso /mnt/mydistro out/my.iso     # stage 5: non-root
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

STAGE_IDS=(seed stage1 stage2 stage3 rootfs iso)
declare -A STAGE_DESC=(
    [seed]="assemble the prebuilt toolchain (seed.tar.zst)"
    [stage1]="unpack seed, mount, chroot, verify toolchain"
    [stage2]="DPM builds the full recipe graph"
    [stage3]="self-hosting rebuild (seed removed)"
    [rootfs]="final root -> rootfs.tar.zst (also the next build's seed)"
    [iso]="initramfs + squashfs + grub -> bootable ISO"
)
SEED_TAR="$HERE/seed/seed.tar.zst"
SEED_SHA256="$SEED_TAR.sha256"

usage() {
    cat <<EOF
$PROG — build the whole distribution: empty directory -> bootable ISO

Usage:
  sudo $PROG [options] TARGET [OUT_ISO]

Stages (resume is automatic: a stage is skipped only when its stamp exists
AND the inputs recorded with it still match — options, recipes, scripts):
  seed    ${STAGE_DESC[seed]}
  stage1  ${STAGE_DESC[stage1]}
  stage2  ${STAGE_DESC[stage2]}
  stage3  ${STAGE_DESC[stage3]}
  rootfs  ${STAGE_DESC[rootfs]}
  iso     ${STAGE_DESC[iso]}

Options:
  --from-stage S    start at S: seed|0, 1, 2, 3, rootfs|4, iso|5 (default: first incomplete)
  --fresh           clear completion stamps; every stage re-runs
  --wipe            delete TARGET entirely first (implies --fresh)
  --no-iso          do not build the ISO
  --no-rootfs       do not pack the rootfs tarball
  --seed-rootfs F   use rootfs tarball F (published by a previous build) as the
                    seed instead of the Debian-based seed.tar.zst: the distro
                    builds itself with its own toolchain. Replaces stage 0.
  --seed-rootfs-sha256 H
                    expected sha256 of the --seed-rootfs file (in addition to
                    its .sha256 sidecar, which is checked when present)
  --keep-mounts     do not unmount the chroot bind mounts at the end
  --single-root     legacy layout: install into the build root only and pack
                    TARGET itself into the ISO (default: TWO roots — see below)
  --stage3-world    STAGE3_WORLD=1 — rebuild EVERY package in stage 3
  --with-gui        WITH_GUI=1 — include recipes/gui in stage 2/3
  --isolation LVL   none|env|sandbox|closure (default none); closure applies
                    to stage 3 only, stage 2 then uses sandbox
  --jobs N          parallel jobs (default: nproc, else 4)
  --vol-id NAME     ISO volume id (default MYDISTRO)
  --squash-comp C   gzip|xz|zstd (default gzip)
  --out PATH        ISO output path (default <repo>/out/mydistro-x86_64.iso)
  --rootfs-out PATH rootfs tarball path (default: the ISO path with
                    .iso replaced by -rootfs.tar.zst)
  --list-stages     show pipeline progress for TARGET and exit
  --dry-run         print what would run; execute and write nothing
  -h, --help        this text

Two-root layout (default):
  build root   TARGET            seed toolchain + build tools; every package is
                                 installed here so later builds can link to it
  final root   TARGET/sysroot    a CLEAN system, only distro packages (no seed,
                                 no build dirs) — the ISO is made from THIS
  Switching layouts between runs invalidates stage 2 onward automatically.

Arguments:
  TARGET            the build root (e.g. /mnt/mydistro); the final root is TARGET/sysroot
  OUT_ISO           ISO output path (positional alternative to --out)

Outputs: OUT_ISO, ROOTFS (+ ROOTFS.sha256, ROOTFS.packages). Publish all of
them; feed ROOTFS to the next build with --seed-rootfs.

Examples:
  sudo $PROG /mnt/mydistro
  sudo $PROG --isolation closure --stage3-world --with-gui /mnt/mydistro my.iso
  $PROG --seed-rootfs out/mydistro-x86_64-rootfs.tar.zst /mnt/mydistro   # self-hosting
  $PROG --from-stage iso /mnt/mydistro my.iso      # stage 5 runs fine as non-root
  $PROG --list-stages /mnt/mydistro
EOF
}

die() { echo "$PROG: error: $*" >&2; exit 2; }
note() { echo "$PROG: $*"; }

# ---------------------------------------------------------------- arguments --
TARGET="" OUT_ISO="" FROM_STAGE="" OUT_ROOTFS="" SEED_ROOTFS="" SEED_ROOTFS_SHA256=""
OPT_FRESH=0 OPT_WIPE=0 OPT_NO_ISO=0 OPT_NO_ROOTFS=0 OPT_KEEP_MOUNTS=0
OPT_WORLD=0 OPT_GUI=0 OPT_LIST=0 OPT_DRYRUN=0 OPT_SINGLE=0
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
        --no-rootfs)    OPT_NO_ROOTFS=1; shift ;;
        --seed-rootfs)  [[ $# -ge 2 ]] || die "--seed-rootfs needs a value"; SEED_ROOTFS="$2"; shift 2 ;;
        --seed-rootfs-sha256) [[ $# -ge 2 ]] || die "--seed-rootfs-sha256 needs a value"; SEED_ROOTFS_SHA256="$2"; shift 2 ;;
        --rootfs-out)   [[ $# -ge 2 ]] || die "--rootfs-out needs a value"; OUT_ROOTFS="$2"; shift 2 ;;
        --keep-mounts)  OPT_KEEP_MOUNTS=1; shift ;;
        --single-root)  OPT_SINGLE=1; shift ;;
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
# effective per-stage isolation: stage 2 builds the archive set that
# `closure` needs, so closure cannot apply there — fold it to sandbox (the
# strongest level stage2 supports). Precomputed here because the stage input
# fingerprints below record exactly these effective values.
if [[ $OPT_ISOLATION == closure ]]; then STAGE2_ISO=sandbox; else STAGE2_ISO=$OPT_ISOLATION; fi
STAGE3_ISO=$OPT_ISOLATION
case "$SQUASH_COMP" in gzip|xz|zstd) ;; *) die "--squash-comp must be gzip|xz|zstd" ;; esac
if [[ -z $JOBS ]]; then JOBS="$(nproc 2>/dev/null || echo 4)"; fi
[[ $JOBS =~ ^[0-9]+$ && $JOBS -ge 1 ]] || die "--jobs must be a positive integer (got '$JOBS')"

TARGET="$(realpath -m -- "$TARGET")"
[[ $TARGET != "/" ]] || die "refusing to use / as the target"
STATE="$(dirname -- "$TARGET")/.$(basename -- "$TARGET").build"
STAMPS="$STATE/stamps"
LOGS="$STATE/logs"
META="$STATE/meta"
LAYOUT_FILE="$STATE/layout"
if (( OPT_SINGLE )); then LAYOUT=single-root; FINAL_HOST="$TARGET"
else                      LAYOUT=two-root;    FINAL_HOST="$TARGET/sysroot"; fi
if [[ -n $OUT_ISO ]]; then OUT_ISO="$(realpath -m -- "$OUT_ISO")"
else OUT_ISO="$REPO/out/mydistro-x86_64.iso"; fi
if [[ -n $OUT_ROOTFS ]]; then OUT_ROOTFS="$(realpath -m -- "$OUT_ROOTFS")"
else OUT_ROOTFS="${OUT_ISO%.iso}-rootfs.tar.zst"; fi
[[ $OUT_ROOTFS == *.tar.zst ]] || die "--rootfs-out must end in .tar.zst (got '$OUT_ROOTFS')"
if [[ -n $SEED_ROOTFS ]]; then
    SEED_ROOTFS="$(realpath -m -- "$SEED_ROOTFS")"
    [[ -f $SEED_ROOTFS ]] || die "--seed-rootfs: $SEED_ROOTFS does not exist"
    [[ $SEED_ROOTFS != "$OUT_ROOTFS" ]] || die "--seed-rootfs and the rootfs output are the same file ($OUT_ROOTFS)"
    [[ -z $SEED_ROOTFS_SHA256 || $SEED_ROOTFS_SHA256 =~ ^[0-9a-fA-F]{64}$ ]] \
        || die "--seed-rootfs-sha256 must be 64 hex digits"
elif [[ -n $SEED_ROOTFS_SHA256 ]]; then
    die "--seed-rootfs-sha256 needs --seed-rootfs"
fi
if [[ -n $SEED_ROOTFS && $FROM_STAGE =~ ^(seed|0)$ ]]; then
    die "--from-stage seed is meaningless with --seed-rootfs (a rootfs seed is not built here)"
fi

if [[ $EUID -ne 0 && $OPT_LIST -eq 0 ]]; then
    note "WARNING: not root — only '--from-stage iso' (stage 5) can work without root"
fi

# ------------------------------------------------- --wipe safety refusals --
# --wipe rm -rf's the target: refuse everything that must never be deleted —
# FHS top-level dirs and their system interiors, the repo itself, every
# ancestor of the repo (a target above it would swallow it), $HOME, and any
# live mountpoint (TARGET itself or a pseudo-fs still mounted INSIDE it —
# deleting through a bind of /dev would destroy the host's device nodes).
# These checks are PURE: they run before any state is created, so a refused
# target does not even get a state directory next to it.
if (( OPT_WIPE )); then
    case "$TARGET" in
        "/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib32"|"/lib64"|"/libx32"|"/media"|"/mnt"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/var")
            die "refusing to --wipe $TARGET (protected system path)" ;;
        "/bin/"*|"/boot/"*|"/dev/"*|"/etc/"*|"/lib/"*|"/lib32/"*|"/lib64/"*|"/libx32/"*|"/opt/"*|"/proc/"*|"/root/"*|"/run/"*|"/sbin/"*|"/srv/"*|"/sys/"*|"/usr/"*|"/var/"*)
            die "refusing to --wipe $TARGET (protected system path)" ;;
    esac
    _p="$REPO"
    while [[ -n $_p && $_p != "/" ]]; do
        [[ $TARGET == "$_p" ]] && die "refusing to --wipe $TARGET (it contains the repository)"
        _p="$(dirname -- "$_p")"
    done
    _p="$HOME"
    while [[ -n $_p && $_p != "/" ]]; do
        [[ $TARGET == "$_p" ]] && die "refusing to --wipe $TARGET (it is a home directory)"
        _p="$(dirname -- "$_p")"
    done
    if [[ -e $TARGET ]]; then
        if mountpoint -q "$TARGET"; then die "refusing to --wipe a mountpoint"; fi
        for _m in dev proc sys run; do
            if mountpoint -q "$TARGET/$_m" 2>/dev/null; then
                die "refusing to --wipe: $TARGET/$_m is still mounted — run first:
       sudo $HERE/umount-chroot.sh $TARGET"
            fi
        done
    fi
fi

# non-empty target with no recorded progress = probably not what the user
# wants (stage1 would unpack the seed over unrelated files). Read-only and
# wipe modes are exempt: --list-stages inspects anything, --wipe replaces it.
if [[ -d $TARGET && -n "$(ls -A "$TARGET" 2>/dev/null)" && ! -d $STAMPS ]] \
   && (( ! OPT_WIPE && ! OPT_DRYRUN && ! OPT_LIST )); then
    die "TARGET $TARGET is not empty and has no build state
       - to replace its contents deliberately: re-run with --wipe
       - or pick a fresh directory"
fi

# --------------------------------------------------------------- state lock --
# Two builds against the same TARGET would interleave stamp/log/state writes
# and corrupt each other's resume state. Hold an exclusive lock for the whole
# run, acquired only after every refusal so a rejected invocation creates
# nothing (read-only modes --list-stages/--dry-run take no lock at all).
if (( ! OPT_DRYRUN && ! OPT_LIST )); then
    mkdir -p "$STATE"
    exec 9>>"$STATE/lock"
    if ! flock -n 9; then
        die "another build-all is already running against $TARGET (lock: $STATE/lock)
             If that is wrong, find and stop the other process first."
    fi
fi

# ------------------------------------------------------------------- stamps --
# A stamp is only trustworthy together with the inputs that produced it.
# Every finished stage records a fingerprint of its contract (stage scripts,
# recipe/profile trees, the effective options) in <stage>.inputs; a later run
# invalidates the stage — and everything downstream — when the fingerprint
# changes. See the invalidation blocks below.
stamp_file() { printf '%s/%s.done' "$STAMPS" "$1"; }
inputs_file() { printf '%s/%s.inputs' "$STAMPS" "$1"; }
failed_file() { printf '%s/failed-%s' "$STATE" "$1"; }
stage_done() { [[ -f "$(stamp_file "$1")" ]]; }

hash_files() {   # one sha256 over the named files (name + content each)
    local f out=""
    for f in "$@"; do
        out+="$(basename -- "$f"):"
        if [[ -f $f ]]; then out+="$(sha256sum "$f" | cut -d' ' -f1)"
        else out+="MISSING"; fi
        out+=$'\n'
    done
    printf '%s' "$out" | sha256sum | cut -d' ' -f1
}

tree_hash() {   # $1 = dir inside the repo: hash of every recipe.toml path+content
    ( cd "$REPO" 2>/dev/null && find "$1" -name 'recipe.toml' -print0 | sort -z \
        | xargs -0 -r sha256sum ) 2>/dev/null | sha256sum | cut -d' ' -f1
}

seed_identity() {   # size+mtime: cheap, and changes whenever the seed is rebuilt
    if [[ -n $SEED_ROOTFS ]]; then
        # a rootfs seed is identified by its published checksum (the sidecar,
        # or the pin) so re-downloading the SAME release does not invalidate
        # stage 1; without either, size+mtime like the Debian seed
        if [[ -n $SEED_ROOTFS_SHA256 ]]; then echo "rootfs:${SEED_ROOTFS_SHA256,,}"
        elif [[ -f $SEED_ROOTFS.sha256 ]]; then echo "rootfs:$(cut -d' ' -f1 "$SEED_ROOTFS.sha256")"
        else echo "rootfs:$(stat -c '%s:%Y' "$SEED_ROOTFS")"; fi
    elif [[ -e $SEED_TAR ]]; then stat -c '%s:%Y' "$SEED_TAR"
    else echo none; fi
}

# stages the user switched off (--no-iso / --no-rootfs): never run, never
# block "first incomplete stage", never counted as pending
stage_skipped() {
    [[ $1 == iso && $OPT_NO_ISO -eq 1 ]] || [[ $1 == rootfs && $OPT_NO_ROOTFS -eq 1 ]]
}

stage_inputs() {   # the input contract of a stage, one key=value per line
    case "$1" in
        seed)   printf 'format=1\nscripts=%s\n' \
                    "$(hash_files "$HERE/seed/build-seed.sh")" ;;
        stage1) printf 'format=1\nscripts=%s\nseed=%s\n' \
                    "$(hash_files "$HERE/stage1.sh" "$HERE/stage1-inner.sh" "$HERE/sync-repo.sh" \
                         "$HERE/seed-from-rootfs.sh" \
                         "$HERE/ensure-chroot-mounts.sh" "$HERE/enter-root.sh")" \
                    "$(seed_identity)" ;;
        stage2) printf 'format=1\nscripts=%s\nrecipes=%s\nprofiles=%s\ngui=%s\nisolation=%s\nlayout=%s\n' \
                    "$(hash_files "$HERE/stage2.sh" "$HERE/stage2-inner.sh" "$HERE/sync-repo.sh" \
                         "$HERE/final-root.sh" "$HERE/ensure-chroot-mounts.sh" "$HERE/enter-root.sh")" \
                    "$(tree_hash recipes)" "$(tree_hash profiles)" \
                    "$OPT_GUI" "$STAGE2_ISO" "$LAYOUT" ;;
        stage3) printf 'format=1\nscripts=%s\nrecipes=%s\nprofiles=%s\ngui=%s\nworld=%s\nisolation=%s\nlayout=%s\n' \
                    "$(hash_files "$HERE/stage3.sh" "$HERE/stage3-inner.sh" "$HERE/sync-repo.sh" \
                         "$HERE/final-root.sh" "$HERE/ensure-chroot-mounts.sh" "$HERE/enter-root.sh")" \
                    "$(tree_hash recipes)" "$(tree_hash profiles)" \
                    "$OPT_GUI" "$OPT_WORLD" "$STAGE3_ISO" "$LAYOUT" ;;
        rootfs) printf 'format=1\nscripts=%s\nlevel=%s\nlayout=%s\n' \
                    "$(hash_files "$HERE/mkrootfs.sh")" \
                    "${ROOTFS_ZSTD_LEVEL:-12}" "$LAYOUT" ;;
        iso)    printf 'format=1\nscripts=%s\nvolid=%s\ncomp=%s\nlayout=%s\n' \
                    "$(hash_files "$HERE/mkiso.sh" "$HERE/initramfs.sh")" \
                    "$VOL_ID" "$SQUASH_COMP" "$LAYOUT" ;;
    esac
}

# stage_valid: 0 = stamp exists AND inputs match; 1 = no stamp;
# 2 = stamp predates input tracking (unverifiable)
stage_valid() {
    local s="$1"
    [[ -f "$(stamp_file "$s")" ]] || return 1
    [[ -f "$(inputs_file "$s")" ]] || return 2
    [[ "$(stage_inputs "$s")" == "$(cat "$(inputs_file "$s")")" ]]
}

# The seed built by build-seed.sh writes a sha256 sidecar next to the
# tarball. Adopting a hand-built seed without one stays possible (legacy
# behavior), but a tarball that FAILS its own sidecar is corrupt and must
# be rebuilt, not adopted.
seed_adoptable() {
    # a rootfs seed REPLACES stage 0: the Debian seed is neither built nor used
    # (checked for existence at argument parsing; its checksum is verified by
    # stage 1, right before it is unpacked)
    [[ -n $SEED_ROOTFS ]] && return 0
    [[ -s $SEED_TAR && ${OPT_FRESH:-0} -eq 0 ]] || return 1
    if [[ -f $SEED_SHA256 ]]; then
        if (cd "$(dirname -- "$SEED_TAR")" && \
            sha256sum -c --quiet "$(basename -- "$SEED_TAR").sha256") >/dev/null 2>&1; then
            return 0
        fi
        echo "$PROG: seed failed its sha256 sidecar — NOT adopting it (seed stage will rebuild)" >&2
        return 1
    fi
    return 0
}

stage_complete() {   # valid stamp, or an adoptable seed
    local s="$1" rc=0
    stage_valid "$s" || rc=$?
    (( rc == 0 )) && return 0
    if [[ $s == seed && $rc == 1 ]] && seed_adoptable; then return 0; fi
    return 1
}

# drop stamps + inputs + failure markers of stage index $1 and everything after
invalidate_from() {
    local from="$1" j id
    for (( j = from; j < ${#STAGE_IDS[@]}; j++ )); do
        id=${STAGE_IDS[$j]}
        rm -f "$(stamp_file "$id")" "$(inputs_file "$id")" "$(failed_file "$id")"
    done
    return 0
}

stage_index() {  # accept seed|0..3|iso|4 -> index into STAGE_IDS
    case "$1" in
        seed|0) echo 0 ;;
        1)      echo 1 ;;
        2)      echo 2 ;;
        3)      echo 3 ;;
        rootfs|4) echo 4 ;;
        iso|5)  echo 5 ;;
        *)      return 1 ;;
    esac
}

list_stages() {
    local i id status n=0 stale=0 failed=0 rc
    echo "target: $TARGET"
    echo "final:  $FINAL_HOST ($LAYOUT)"
    echo "state:  $STATE"
    echo
    printf '  %-8s %-50s %s\n' STAGE DESCRIPTION STATUS
    for i in "${!STAGE_IDS[@]}"; do
        id=${STAGE_IDS[$i]}
        status=""
        if [[ -f "$(failed_file "$id")" && ! -f "$(stamp_file "$id")" ]]; then
            status="FAILED (see $LOGS)"
            failed=$((failed+1))
        elif stage_skipped "$id"; then
            status="skipped (--no-${id})"
        elif stage_done "$id"; then
            rc=0; stage_valid "$id" || rc=$?
            when="$(stat -c %y "$(stamp_file "$id")" 2>/dev/null | cut -d. -f1)"
            case $rc in
                0) status="done $when"; n=$((n+1)) ;;
                2) status="stale (inputs not recorded) $when"; stale=$((stale+1)) ;;
                *) status="stale (inputs changed) $when";  stale=$((stale+1)) ;;
            esac
        elif [[ $id == seed && -n $SEED_ROOTFS ]]; then
            status="not needed (rootfs seed: $(basename -- "$SEED_ROOTFS"))"
            n=$((n+1))
        elif [[ $id == seed ]] && seed_adoptable; then
            status="done (adopted $(stat -c %y "$SEED_TAR" 2>/dev/null | cut -d. -f1))"
            n=$((n+1))
        else
            status="pending"
        fi
        printf '  %-8s %-50s %s\n' "$id" "${STAGE_DESC[$id]}" "$status"
    done
    echo
    echo "  $n/${#STAGE_IDS[@]} stages recorded as complete"
    (( stale > 0 )) && echo "  $stale stale (inputs changed/unknown — re-run rebuilds them)"
    (( failed > 0 )) && echo "  $failed failed (re-run resumes there)"
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
        die "stages 1-3 need root; re-run with sudo, or use --from-stage iso for the non-root stage 5"
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
                # a rootfs seed is not built; nothing to check here
                [[ -n $SEED_ROOTFS ]] || command -v curl >/dev/null || die "seed stage needs curl on the host"
                ;;
            rootfs)
                missing=()
                for t in tar zstd sha256sum; do
                    command -v "$t" >/dev/null || missing+=("$t")
                done
                if (( ${#missing[@]} > 0 )); then
                    die "rootfs stage misses host tool(s): ${missing[*]} (Debian: apt install zstd tar coreutils)"
                fi
                ;;
            stage1|stage2|stage3)
                missing=()
                for t in tar zstd unshare pivot_root mount; do
                    command -v "$t" >/dev/null || missing+=("$t")
                done
                if (( ${#missing[@]} > 0 )); then
                    die "stages 1-3 need host tool(s): ${missing[*]} (Debian: apt install zstd util-linux tar)"
                fi
                ;;
            iso)
                missing=()
                for t in mksquashfs grub-mkrescue xorriso gcc make; do
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
    if [[ -n $SEED_ROOTFS && $SEED_ROOTFS_SHA256 == "" && ! -f $SEED_ROOTFS.sha256 ]]; then
        note "WARNING: no $(basename -- "$SEED_ROOTFS").sha256 next to the rootfs seed and no --seed-rootfs-sha256: its integrity beyond zstd's frame CRC is NOT verified"
    fi
}

# ---------------------------------------------------------------- pipeline ---
CURRENT_STAGE="(pre-flight)"
LOG=""
trap 'on_exit $?' EXIT
on_exit() {
    local rc=$1
    if (( rc != 0 && rc != 2 )); then
        # record WHICH stage failed so --list-stages can distinguish a
        # failure from a pending stage (the marker is cleared when that
        # stage later succeeds)
        if [[ -n $LOG && $CURRENT_STAGE != "(pre-flight)" ]]; then
            touch "$(failed_file "$CURRENT_STAGE")" 2>/dev/null || true
            printf '%s|%s|-|FAIL\n' "$CURRENT_STAGE" "$(date -Is)" >> "$META" 2>/dev/null || true
        fi
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

# layout switch (two-root <-> single-root): stage 2 onward installed packages
# into the OTHER layout, so their stamps are stale. A build that predates the
# layout file is a single-root build.
if [[ -d $STAMPS ]] && (( ! OPT_LIST )); then
    PREV_LAYOUT=single-root
    [[ -f $LAYOUT_FILE ]] && PREV_LAYOUT="$(cat "$LAYOUT_FILE")"
    if [[ $PREV_LAYOUT != "$LAYOUT" ]]; then
        for id in stage2 stage3 rootfs iso; do
            if [[ -f "$(stamp_file "$id")" ]]; then
                note "invalidating stamp: $id (layout $PREV_LAYOUT -> $LAYOUT)"
                if (( ! OPT_DRYRUN )); then rm -f "$(stamp_file "$id")" "$(inputs_file "$id")" "$(failed_file "$id")"; fi
            fi
        done
    fi
fi

# stamp input validation: a stamp whose recorded inputs no longer match the
# current invocation — or that predates input tracking — is stale. Invalidate
# it and everything downstream (upstream stages are untouched: their inputs
# did not change). This is what makes --with-gui, --stage3-world, --vol-id,
# --squash-comp, recipe edits and stage-script edits resume-correct instead
# of being silently skipped. Every stale stamp is reported (so a legacy
# build shows all five), then the cascade starts at the FIRST stale one.
# Skipped for --fresh/--wipe (everything re-runs anyway) and for the
# read-only --dry-run/--list-stages modes.
if [[ -d $STAMPS ]] && (( ! OPT_LIST && ! OPT_DRYRUN && ! OPT_FRESH && ! OPT_WIPE )); then
    first_stale=-1
    for i in "${!STAGE_IDS[@]}"; do
        id=${STAGE_IDS[$i]}
        [[ -f "$(stamp_file "$id")" ]] || continue
        rc=0; stage_valid "$id" || rc=$?
        if (( rc == 0 )); then continue; fi
        if (( rc == 2 )); then
            note "invalidating stamp: $id (pre-dates input tracking — its inputs cannot be verified)"
        else
            changed="$(diff <(cat "$(inputs_file "$id")") <(stage_inputs "$id") 2>/dev/null \
                     | grep '^>' | sed 's/^> *//' | cut -d= -f1 | tr '\n' ' ' || true)"
            changed="${changed% }"
            note "invalidating stamp: $id (inputs changed: ${changed:-unknown})"
        fi
        (( first_stale < 0 )) && first_stale=$i
    done
    if (( first_stale >= 0 )); then
        note "stamps after the first stale one are dropped with it (a stamp is only valid while every upstream stamp stayed valid)"
        invalidate_from "$first_stale"
    fi
fi

# decide where the run starts
if [[ -n $FROM_STAGE ]]; then
    START="$(stage_index "$FROM_STAGE")" || die "--from-stage must be seed|0|1|2|3|rootfs|4|iso|5 (got '$FROM_STAGE')"
else
    START=${#STAGE_IDS[@]}
    for i in "${!STAGE_IDS[@]}"; do
        if stage_skipped "${STAGE_IDS[$i]}"; then continue; fi
        if ! stage_complete "${STAGE_IDS[$i]}"; then START=$i; break; fi
    done
fi
END=$(( ${#STAGE_IDS[@]} - 1 ))

# --wipe execution (the safety refusals already ran before the lock)
if (( OPT_WIPE && ! OPT_LIST )) && [[ -e $TARGET ]]; then
    note "--wipe: deleting $TARGET ($(du -sh --exclude=proc --exclude=sys --exclude=dev --exclude=run "$TARGET" 2>/dev/null | cut -f1 || echo unknown size))"
    if (( ! OPT_DRYRUN )); then rm -rf -- "$TARGET"; fi
fi
if (( OPT_FRESH && ! OPT_LIST )) && [[ -d $STAMPS ]]; then
    note "--fresh: clearing stage stamps in $STAMPS"
    if (( ! OPT_DRYRUN )); then rm -rf -- "$STAMPS"; fi
fi
# forcing a start point invalidates that stage and everything after it
# ("start at stage 2" means stage 2 RUNS, stamps from stage 2 onward are stale)
if [[ -n $FROM_STAGE ]] && (( ! OPT_LIST )); then
    for i in "${!STAGE_IDS[@]}"; do
        if (( i < START )); then continue; fi
        if [[ -f "$(stamp_file "${STAGE_IDS[$i]}")" ]]; then
            note "invalidating stamp: ${STAGE_IDS[$i]} (restarting at $FROM_STAGE)"
            if (( ! OPT_DRYRUN )); then rm -f "$(stamp_file "${STAGE_IDS[$i]}")" "$(inputs_file "${STAGE_IDS[$i]}")" "$(failed_file "${STAGE_IDS[$i]}")"; fi
        fi
    done
fi

if (( OPT_LIST )); then list_stages; fi

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
# STAGE2_ISO/STAGE3_ISO were computed above (input tracking needs them
# before any stamp is compared); stage2 cannot do closure — see there
export STAGE2_ISOLATION="$STAGE2_ISO"
if [[ $OPT_ISOLATION == closure ]]; then
    echo "$PROG: note: --isolation closure applies to stage 3; stage 2 uses sandbox"
fi
export STAGE3_ISOLATION="$STAGE3_ISO"
export SINGLE_ROOT="$OPT_SINGLE"
export STAGE3_WORLD="$OPT_WORLD"
# stage1 reads these: a rootfs seed replaces seed.tar.zst (empty = Debian seed)
export SEED_ROOTFS SEED_ROOTFS_SHA256
export VOL_ID SQUASH_COMP JOBS="$JOBS"

# logging (never in --dry-run: it must not touch anything)
if (( ! OPT_DRYRUN )); then
    mkdir -p "$LOGS"
    echo "$LAYOUT" > "$LAYOUT_FILE"
    LOG="$LOGS/build-$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
    # audit header — the task's "record effective tool versions and important
    # configuration inputs": every log names the exact host, tools and seed
    # that produced the build, so a later failure can be attributed
    {
        echo "== build-all audit header"
        echo "started:   $(date -Is)"
        echo "args:      ${ORIG_ARGS[*]:-}"
        echo "host:      $(uname -srm)"
        echo "repo:      $REPO"
        echo "bash:      $BASH_VERSION"
        echo "tar:       $(tar --version 2>/dev/null | head -1)"
        echo "zstd:      $(zstd --version 2>/dev/null | head -1 || echo missing)"
        echo "seed:      $(seed_identity)"
        [[ -n $SEED_ROOTFS ]] && echo "seed-kind: rootfs ($SEED_ROOTFS)"
        if command -v git >/dev/null 2>&1 && [[ -e $REPO/.git ]]; then
            git -C "$REPO" rev-parse HEAD 2>/dev/null | sed 's/^/commit:    /'
        fi
        echo "== end audit header"
    }
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
RAN_ISO=0 RAN_ROOTFS=0
run_stage() {
    local id="$1" idx="$2" t0 t1 el
    CURRENT_STAGE="$id"
    banner "stage $id — ${STAGE_DESC[$id]}"
    # upstream-continuity invariant: a stage that runs makes every LATER
    # stamp meaningless (they were produced from this stage's previous
    # output), so drop them before rebuilding — a stamp is only valid while
    # every upstream stamp stayed valid
    if (( ! OPT_DRYRUN )); then invalidate_from $(( idx + 1 )); fi
    t0=$(date +%s)
    case $id in
        seed)   CMD=(bash "$HERE/seed/build-seed.sh") ;;
        stage1) CMD=(bash "$HERE/stage1.sh" "$TARGET") ;;
        stage2) CMD=(bash "$HERE/stage2.sh" "$TARGET") ;;
        stage3) CMD=(bash "$HERE/stage3.sh" "$TARGET") ;;
        rootfs) CMD=(bash "$HERE/mkrootfs.sh" "$FINAL_HOST" "$OUT_ROOTFS") ;;
        iso)    CMD=(bash "$HERE/mkiso.sh" "$FINAL_HOST" "$OUT_ISO") ;;
    esac
    if [[ $id == iso || $id == rootfs ]] && (( ! OPT_DRYRUN )) && [[ ! -d $FINAL_HOST ]]; then
        die "final root $FINAL_HOST does not exist — run stage 2 (and 3) first (layout: $LAYOUT)"
    fi
    if (( OPT_DRYRUN )); then
        echo "[dry-run] would run:  ${CMD[*]}"
        echo "[dry-run] would stamp: $(stamp_file "$id") (inputs recorded in $(inputs_file "$id"))"
    else
        "${CMD[@]}"
        mkdir -p "$STAMPS"
        date > "$(stamp_file "$id")"
        stage_inputs "$id" > "$(inputs_file "$id")"
        rm -f "$(failed_file "$id")"
        t1=$(date +%s); el=$((t1 - t0))
        printf '%s|%s|%ss|ok\n' "$id" "$(date -Is)" "$el" >> "$META"
        STAGE_ELAPSED+=("$(printf '%-8s took %s' "$id" "$(fmt_el "$el")")")
        echo "== $PROG: stage $id finished in $(fmt_el "$el")"
    fi
    [[ $id == iso ]] && RAN_ISO=1
    [[ $id == rootfs ]] && RAN_ROOTFS=1
    return 0
}

T_START=$(date +%s)
banner "mydistro build — target $TARGET"
echo "  jobs=$JOBS  isolation=$OPT_ISOLATION  gui=$OPT_GUI  stage3-world=$OPT_WORLD"
echo "  layout=$LAYOUT  build-root=$TARGET  final-root=$FINAL_HOST"
echo "  state=$STATE"
echo "  iso output: $OUT_ISO"
echo "  rootfs out: $OUT_ROOTFS"
if [[ -n $SEED_ROOTFS ]]; then echo "  seed:       ROOTFS $SEED_ROOTFS (self-hosting)"; fi
if (( OPT_DRYRUN )); then echo "  (dry run — nothing is executed or recorded)"; fi

# a hand-built seed adopted as done is worth saying out loud — but only when
# the seed will actually be SKIPPED (START > 0); with `--from-stage seed` the
# stage runs even when adoptable, and announcing an adoption there would lie
if (( ! OPT_DRYRUN )) && (( START > 0 )) && ! stage_done seed && seed_adoptable; then
    if [[ -n $SEED_ROOTFS ]]; then note "seed: using the rootfs $SEED_ROOTFS (stage 0 not needed)"
    else note "seed: adopting existing $SEED_TAR (no stamp yet)"; fi
fi

if (( START > END )); then
    note "nothing to run: every stage in range is already complete"
    if (( ! OPT_NO_ISO )) && [[ -s $OUT_ISO ]]; then
        note "ISO from a previous run: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
    fi
    if (( ! OPT_NO_ROOTFS )) && [[ -s $OUT_ROOTFS ]]; then
        note "rootfs from a previous run: $OUT_ROOTFS ($(du -h "$OUT_ROOTFS" | cut -f1))"
    fi
fi

for (( i = START; i <= END; i++ )); do
    id=${STAGE_IDS[$i]}
    if stage_skipped "$id"; then
        echo "-- $PROG: $id skipped (--no-$id)"
        continue
    fi
    if (( OPT_DRYRUN )); then
        run_stage "$id" "$i"
    elif [[ -n $FROM_STAGE && $i -eq $START ]]; then
        # --from-stage S documents that S itself re-runs. That must hold even
        # for the seed, where adoption would otherwise quietly skip it.
        run_stage "$id" "$i"
    elif stage_complete "$id"; then
        if [[ $id == seed ]] && ! stage_done seed; then
            if [[ -n $SEED_ROOTFS ]]; then note "seed: not needed, using the rootfs seed"
            else note "seed: adopting existing $SEED_TAR (no stamp yet)"; fi
        fi
        echo "-- $PROG: $id already done (inputs unchanged), skipping"
    else
        run_stage "$id" "$i"
    fi
done

# ---------------------------------------------------------------- epilogue ---
if (( ! OPT_DRYRUN )); then
    if (( ${#STAGE_ELAPSED[@]} > 0 )); then
        echo
        echo "== $PROG: stages completed this run:"
        printf '  %s\n' "${STAGE_ELAPSED[@]}"
    fi
    if (( RAN_ROOTFS )); then
        if [[ -s $OUT_ROOTFS && -s $OUT_ROOTFS.sha256 ]]; then
            echo "== $PROG: rootfs ready: $OUT_ROOTFS ($(du -h "$OUT_ROOTFS" | cut -f1))"
        else
            echo "$PROG: rootfs (or its .sha256) missing after the rootfs stage: $OUT_ROOTFS" >&2
            exit 1
        fi
    fi
    if (( RAN_ISO )); then
        if [[ -s $OUT_ISO ]]; then
            echo "== $PROG: ISO ready: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
        else
            echo "$PROG: ISO missing after stage 5: $OUT_ISO" >&2
            exit 1
        fi
    elif (( OPT_NO_ISO )); then
        note "no ISO (--no-iso); produce it later with:
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
    echo "   - next build, self-hosting:  $0 --seed-rootfs $OUT_ROOTFS <new-target>"
    echo "   - install to disk (in live): sudo install.sh /dev/vda --yes"
fi
