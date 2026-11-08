#!/usr/bin/env bash
# scripts/fetch-rootfs-seed.sh — download the rootfs published by the newest
# release that carries one, to use it as the seed of THIS build
# (`build-all.sh --seed-rootfs <printed path>`): the distribution then builds
# itself with the toolchain of its previous release.
#
# Release assets (see .github/workflows/release.yml):
#   faseela-x86_64-rootfs.tar.zst  +  faseela-x86_64-rootfs.tar.zst.sha256
# Releases made before the rename carry mydistro-x86_64-rootfs.tar.zst instead;
# it is accepted as a fallback (ROOTFS_LEGACY_ASSET, empty = disabled).
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
# Debian seed) | 4 checksum mismatch | 5 gh / curl download failure | 2 usage
#
# Usage: scripts/fetch-rootfs-seed.sh OUTDIR
# Env:   ROOTFS_ASSET  asset name (default faseela-x86_64-rootfs.tar.zst)
#        ROOTFS_LEGACY_ASSET  older name tried when ROOTFS_ASSET is absent
#                      (default mydistro-x86_64-rootfs.tar.zst)
#        GH_REPO       owner/name of the repository (default: the current one)
#        ROOTFS_MAX_RELEASES  how many releases to look at (default 20)
#        needs gh (authenticated for release metadata) and curl
set -euo pipefail

OUTDIR="${1:?usage: fetch-rootfs-seed.sh OUTDIR}"
ASSET="${ROOTFS_ASSET:-faseela-x86_64-rootfs.tar.zst}"
LEGACY="${ROOTFS_LEGACY_ASSET-mydistro-x86_64-rootfs.tar.zst}"
MAXREL="${ROOTFS_MAX_RELEASES:-20}"
GH_REPO="${GH_REPO:-}"
if [[ -z $GH_REPO ]]; then
    # Resolve the repository from this script's checkout, not the caller's
    # working directory (faseela-repo invokes this script from a sibling tree).
    SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    remote="$(git -C "$SCRIPT_ROOT" remote get-url origin 2>/dev/null || true)"
    case "$remote" in
        https://github.com/*|http://github.com/*)
            GH_REPO="${remote#*github.com/}" ;;
        git@github.com:*)
            GH_REPO="${remote#git@github.com:}" ;;
        ssh://git@github.com/*)
            GH_REPO="${remote#ssh://git@github.com/}" ;;
    esac
    GH_REPO="${GH_REPO%.git}"
    # Preserve the documented "current repository" default for source archives
    # or worktrees that have no GitHub origin configured.
    if [[ -z $GH_REPO ]]; then
        GH_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    fi
fi
[[ "$GH_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    log "set GH_REPO to owner/name (or run from a checkout with a GitHub origin)"
    exit 5
}
REPO_ARGS=(--repo "$GH_REPO")

log() { echo "fetch-rootfs-seed: $*" >&2; }
command -v gh >/dev/null 2>&1 || { log "the gh CLI is required"; exit 5; }
command -v curl >/dev/null 2>&1 || { log "curl is required"; exit 5; }
command -v sha256sum >/dev/null 2>&1 || { log "sha256sum is required"; exit 5; }

tags="$(gh release list "${REPO_ARGS[@]}" --limit "$MAXREL" --json tagName --jq '.[].tagName')" \
    || { log "cannot list the releases"; exit 5; }
if [[ -z $tags ]]; then
    log "the repository has no releases yet"
    exit 3
fi

saw_candidate=0

while IFS= read -r tag; do
    [[ -n $tag ]] || continue
    assets="$(gh release view "$tag" "${REPO_ARGS[@]}" --json assets --jq '.assets[].name')" \
        || { log "cannot read release $tag"; exit 5; }
    asset="$ASSET"
    if ! grep -qxF -- "$asset" <<< "$assets"; then
        if [[ -n $LEGACY ]] && grep -qxF -- "$LEGACY" <<< "$assets"; then
            asset="$LEGACY"
        else
            log "release $tag has no $ASSET — skipping"
            continue
        fi
    fi
    if ! grep -qxF -- "$asset.sha256" <<< "$assets"; then
        log "release $tag has $asset but no $asset.sha256 — not trusted, skipping"
        continue
    fi

    saw_candidate=1
    log "trying rootfs from release $tag ($asset)"
    mkdir -p "$OUTDIR"
    # Public release assets download directly, avoiding the GitHub API asset endpoint.
    release_url="https://github.com/$GH_REPO/releases/download/$tag"

    download_asset() { # URL DESTINATION; keep incomplete downloads out of the usable path
        local url="$1" destination="$2" part="${2}.part"
        rm -f "$part"
        if ! curl --fail --location --silent --show-error \
            --retry 8 --retry-all-errors --retry-delay 5 --retry-max-time 240 \
            --connect-timeout 30 --max-time 1800 \
            --output "$part" "$url" >&2; then
            rm -f "$part"
            return 1
        fi
        if [[ ! -s "$part" ]]; then
            log "$(basename "$destination") from $tag is empty after download"
            rm -f "$part"
            return 1
        fi
        mv -f "$part" "$destination"
    }

    download_failed=0
    for a in "$asset" "$asset.sha256"; do
        if ! download_asset "$release_url/$a" "$OUTDIR/$a"; then
            log "download of $a from $tag failed after retries"
            download_failed=1
            break
        fi
    done
    if (( download_failed )); then
        # A CDN/edge failure is not evidence that the release is corrupt. Try
        # the next older release that carries both files; never use a partial
        # download and never skip checksum verification.
        rm -f "$OUTDIR/$asset" "$OUTDIR/$asset.sha256" \
            "$OUTDIR/$asset.part" "$OUTDIR/$asset.sha256.part"
        log "release $tag is temporarily unavailable; trying an older rootfs release"
        continue
    fi

    # The sidecar is sha256sum format with the bare file name (mkrootfs.sh).
    if ! ( cd "$OUTDIR" && sha256sum -c --quiet "$asset.sha256" ) >&2; then
        log "sha256 of $asset (release $tag) does not match its .sha256 — refusing to use it"
        rm -f "$OUTDIR/$asset" "$OUTDIR/$asset.sha256"
        exit 4
    fi
    log "verified: $(cut -d' ' -f1 "$OUTDIR/$asset.sha256") ($(du -h "$OUTDIR/$asset" | cut -f1))"
    echo "$OUTDIR/$asset"
    exit 0
done <<< "$tags"

if (( saw_candidate )); then
    log "rootfs assets were found in the last $MAXREL release(s), but none could be downloaded"
    exit 5
fi
log "none of the last $MAXREL release(s) carries $ASSET"
exit 3
