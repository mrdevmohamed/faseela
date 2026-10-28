#!/usr/bin/env bash
# scripts/vendor-dpm.sh — (re)generate the vendored crates for dpm.
#
# Run on a developer machine WITH network and cargo, then commit
# pkgmgr/vendor and pkgmgr/.cargo/config.toml together. Re-run whenever
# pkgmgr/Cargo.lock changes. The bootstrap (stage 2) and the `dpm` recipe both
# build offline from these files, so no build step ever needs crates.io.
set -euo pipefail
cd "$(dirname "$0")/../pkgmgr"

# a config that already points at vendor/ would break the fetch below
rm -rf vendor .cargo/config.toml
mkdir -p .cargo
cargo vendor --locked vendor > .cargo/config.toml

# prove the result really is self-contained
cargo build --release --offline --locked
echo "vendored $(find vendor -mindepth 1 -maxdepth 1 -type d | wc -l) crates into pkgmgr/vendor"
echo "now commit: pkgmgr/vendor pkgmgr/.cargo/config.toml"
