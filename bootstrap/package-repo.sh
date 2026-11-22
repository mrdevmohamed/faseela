# bootstrap/package-repo.sh — the package repository an image is installed from.
#
# Sourced by mkflavor.sh and final-root.sh. One place names the endpoint so the
# build, the image's /etc/nawa/nawa.toml and the checks cannot drift apart.
#
# The signed schema-v5 index lives in the `stable-v5` release of faseela-repo.
# FASEELA_PKG_REPO (an http(s) URL or a directory with index.toml) overrides it.
FASEELA_PKG_REPO_DEFAULT="https://github.com/mrdevmohamed/faseela-repo/releases/download/stable-v5"
FASEELA_PKG_REPO="${FASEELA_PKG_REPO:-$FASEELA_PKG_REPO_DEFAULT}"
