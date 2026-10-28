#!/usr/bin/env bash
# scripts/fetch-rootfs-seed.sh — download the rootfs published by the newest
# release that carries one, to use it as the seed of THIS build
# (`build-all.sh --seed-rootfs <printed path>`): the distribution then builds
# itself with the toolchain of its previous release.
#
# Release assets (see .github/workflows/release.yml):
#   mydistro-x86_64-rootfs.tar.zst  +  mydistro-x86_64-rootfs.tar.zst.sha256
#
# A release is only used when BOTH assets are present, and the download is
# verified against the .sha256 before anything uses it. The newest usable
# release wins; releases without a rootfs (e.g. made before this existed) are
# skipped. A checksum mismatch is an error, never a reason to try an older one.
#
# Output: the path of the verified rootfs on stdout (nothing else on stdout);
# progress on stderr.
#
# Exit codes: 0 found + verified | 3 no release carries a rootfs (use the
# Debian seed) | 4 checksum mismatch | 5 gh / download failure | 2 usage
#
# Usage: scripts/fetch-rootfs-seed.sh OUTDIR
# Env:   ROOTFS_ASSET  asset name (default mydistro-x86_64-rootfs.tar.zst)
#        GH_REPO       owner/name of the repository (default: the current one)
#        ROOTFS_MAX_RELEASES  how many releases to look at (default 20)
#        needs the gh CLI, authenticated (GH_TOKEN in Actions)
set -euo pipefail

OUTDIR="${1:?usage: fetch-rootfs-seed.sh OUTDIR}"
ASSET="${ROOTFS_ASSET:-mydistro-x86_64-rootfs.tar.zst}"
MAXREL="${ROOTFS_MAX_RELEASES:-20}"
REPO_ARGS=()
[[ -z ${GH_REPO:-} ]] || REPO_ARGS=(--repo "$GH_REPO")

log() { echo "fetch-rootfs-seed: $*" >&2; }
command -v gh >/dev/null 2>&1 || { log "the gh CLI is required"; exit 5; }
command -v sha256sum >/dev/null 2>&1 || { log "sha256sum is required"; exit 5; }

tags="$(gh release list "${REPO_ARGS[@]}" --limit "$MAXREL" --json tagName --jq '.[].tagName')" \
    || { log "cannot list the releases"; exit 5; }
if [[ -z $tags ]]; then
    log "the repository has no releases yet"
    exit 3
fi

while IFS= read -r tag; do
    [[ -n $tag ]] || continue
    assets="$(gh release view "$tag" "${REPO_ARGS[@]}" --json assets --jq '.assets[].name')" \
        || { log "cannot read release $tag"; exit 5; }
    if ! grep -qxF -- "$ASSET" <<< "$assets"; then
        log "release $tag has no $ASSET — skipping"
        continue
    fi
    if ! grep -qxF -- "$ASSET.sha256" <<< "$assets"; then
        log "release $tag has $ASSET but no $ASSET.sha256 — not trusted, skipping"
        continue
    fi

    log "using the rootfs of release $tag"
    mkdir -p "$OUTDIR"
    for a in "$ASSET" "$ASSET.sha256"; do
        gh release download "$tag" "${REPO_ARGS[@]}" --pattern "$a" --dir "$OUTDIR" --clobber >&2 \
            || { log "download of $a from $tag failed"; rm -f "$OUTDIR/$ASSET" "$OUTDIR/$ASSET.sha256"; exit 5; }
        [[ -s $OUTDIR/$a ]] || { log "$a from $tag is missing or empty after the download"; rm -f "$OUTDIR/$ASSET" "$OUTDIR/$ASSET.sha256"; exit 5; }
    done
    # the sidecar is `sha256sum` format with the bare file name (mkrootfs.sh)
    if ! ( cd "$OUTDIR" && sha256sum -c --quiet "$ASSET.sha256" ) >&2; then
        log "sha256 of $ASSET (release $tag) does not match its .sha256 — refusing to use it"
        rm -f "$OUTDIR/$ASSET" "$OUTDIR/$ASSET.sha256"
        exit 4
    fi
    log "verified: $(cut -d' ' -f1 "$OUTDIR/$ASSET.sha256") ($(du -h "$OUTDIR/$ASSET" | cut -f1))"
    echo "$OUTDIR/$ASSET"
    exit 0
done <<< "$tags"

log "none of the last $MAXREL release(s) carries $ASSET"
exit 3
