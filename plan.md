# plan.md — Faseela bootstrap audit & repair

Scope: `bootstrap/`, orchestration state handling, seed provenance, final-root
boundary, ISO validation, tests, docs. The Rust package manager (pkgmgr) is
NOT modified: all 109 cargo tests, clippy and the recipe validation pass on the
pristine tree; every confirmed defect below lives in the shell layer or in the
orchestration contracts around it.

## Baseline (Phase A results — all executed, all green)

| check | command | result |
|---|---|---|
| shell syntax | `bash -n` on all `bootstrap/*.sh`, `bootstrap/seed/*.sh`, `scripts/*.sh` | OK |
| shellcheck | `shellcheck --severity=error` (as CI) | clean |
| recipes | `python3 -I scripts/check-recipes.py` | 148 recipes, 0 errors, 32 GUI sha256 placeholders |
| orchestration | `bash scripts/test-build-all-mock.sh` | 65 PASS / 0 FAIL |
| final-root | `bash scripts/test-final-root.sh` | 15 PASS / 0 FAIL |
| installer | `bash scripts/validate-install.sh` | PASSED |
| dry run | `bash bootstrap/build-all.sh --dry-run --isolation closure /tmp/mydistro-dry` | exit 0 |
| rust | `cargo build/clippy -D warnings/test --release --locked` (pkgmgr) | build OK, clippy clean, 109/109 tests |

No failing build log ships in the tree (no state dir, no logs). Working tree
is the pristine zip: one snapshot commit `f7f9e86` (local only, nothing pushed).

## Confirmed defects (root causes, not symptoms)

### D1 — Stamps record no inputs: option/recipe changes are silently skipped (HIGH)
`build-all.sh` treats a stage as done when `<stage>.done` exists
(`stage_done`, line ~174); the stamp content is just `date`. Consequences,
each reproducible with the mock harness:
- full build, then `--with-gui`: stage2/3/iso are skipped — the GUI stack is
  never built and the run reports success;
- `--stage3-world` after a default stage3: stage3 skipped;
- `--vol-id X` / `--squash-comp zstd` after iso: skipped, stale ISO reported;
- recipe edits: stage2 skipped (deps-all already skips db-recorded names);
  only a layout switch invalidates anything today.
This is the "resumption trusts stale state" failure class.

**Fix**: write a `<stage>.inputs` sidecar next to each stamp fingerprinting the
stage's contract (script hashes, recipe+profile tree hashes, gui/world/
isolation/volid/comp/layout knobs, seed identity for stage1). On later runs a
stamp whose sidecar mismatches (or is missing = legacy) invalidates that stage
and everything downstream, with a per-key diff notice. Whenever a stage *runs*,
downstream stamps are invalidated (upstream-continuity invariant).

### D2 — `--from-stage seed` does not run seed when adoption applies (MED)
The `--from-stage` invalidation removes stamp files; an adopted seed has no
stamp, so the run loop skips it via `stage_done_or_adopted` — violating the
documented "S itself re-runs" contract.
**Fix**: with `--from-stage`, the start stage always runs (adoption disabled
for it).

### D3 — No concurrency guard (MED)
Nothing prevents two `build-all` runs against the same TARGET from interleaving
stamp/log/state writes.
**Fix**: `flock` the state dir (skipped for `--dry-run`/`--list-stages`).

### D4 — Seed adopted/used without validation (MED)
Adoption checks only `-s` (non-empty). A truncated `seed.tar.zst` is adopted,
then fails mid-unpack *over the target* in stage1.
**Fix**: `build-seed.sh` writes a `seed.tar.zst.sha256` sidecar; adoption and
stage1 verify it when present (absent = hand-built seed: adopt with a loud
"unverified" notice, preserving current behavior), and stage1 runs `zstd -t`
before unpacking.

### D5 — Stage2 re-run after stage3 crashes on the deleted seed (MED)
stage3 removes `/opt/{seed,cargo,rustup,cross-tools}`; a later
`--from-stage 2` then dies at `. /opt/seed/env.sh` (stage2.sh:61) — and would
die again at `cargo build` (stage2-inner.sh:65) even though `/usr/bin/dpm` is
installed and the distro's own toolchain is in place.
**Fix**: source `env.sh` only when present; skip the DPM rebuild when cargo is
unavailable but a working installed dpm exists (fail loudly otherwise).

### D6 — Leftover one-time migration hack `REBUILD_AFTER_CHANGE="readline"` (LOW-MED)
stage2-inner.sh:144-165 hardcodes a readline rebuild on every resume —
leftover from the SHLIB_LIBS fix, incomplete by design (dependents are not
rebuilt) and confusing. **Fix**: remove; document the correct procedures
(`--from-stage 2` for everything, `dpm remove <pkg>` + re-run for one package).

### D7 — ~1 GB seed tarball (and seed-root scratch) copied into the chroot at every stage (MED)
stage1/2/3 `cp -a "$REPO/bootstrap" ...` includes `bootstrap/seed/seed.tar.zst`
plus possibly `bootstrap/seed/seed-root` (multi-GB) and the host's
`pkgmgr/target`. With the documented ~10 GB budget this can starve the build.
**Fix**: new `bootstrap/sync-repo.sh` — tar-based copy with excludes
(`pkgmgr/target`, `bootstrap/seed`, `srccache`, `out`, initramfs scratch);
merge semantics preserved.

### D8 — `--wipe` protected-path list too narrow (HIGH if hit)
Only `/`, `$REPO`, `$HOME`, `dirname $REPO` are refused (line ~329):
`--wipe /usr` proceeds.
**Fix**: refuse exact FHS top-level dirs, every ancestor of `$REPO`/`$HOME`,
`/` (kept), mountpoints (kept); print `du -sh` of what would be deleted.

### D9 — Stage3 toolchain set hardcoded (LOW)
`ORDER="linux-headers glibc binutils m4 gmp mpfr mpc gcc make pkgconf"`
stales when recipes/toolchain changes. **Fix**: derive the set from
`recipes/toolchain/` and keep topological order by filtering `deps-all`.

### D10 — Self-hosting is declared, never verified (HIGH)
Stage3 exits 0 = "self-hosted": no compile test with the distro's own
toolchain after the seed is deleted, no check that key binaries are
db-owned (i.e. ours, not the Debian seed's), no ELF scan for /opt/seed
references in the final root.
**Fix** (stage3-inner, after seed removal):
1. compile+run a pthread C program with `/usr/bin/cc` (PATH has no /opt);
2. `dpm owner` proves /usr/bin/gcc, /usr/bin/dpm are package-owned;
3. readelf-based scan of final-root ELFs for interpreter/NEEDED/RPATH
   referencing /opt/{seed,cargo,rustup,cross-tools} (helper in final-root.sh,
   unit-tested with a deliberately poisoned rpath binary).

### D11 — ISO never structurally validated (MED)
Only "file exists and non-empty" is checked. **Fix**: mkiso fails fast on a
missing xorriso; after grub-mkrescue it verifies via `xorriso -indev -ls`
that `/boot/<kernel>`, `/boot/initramfs.img`, `/boot/grub/grub.cfg` and
`/live/rootfs.squashfs` are present in the image. (Still not a boot test —
documented as such.)

### D12 — build-seed.sh provenance/robustness gaps (MED)
No early root check (the chroot sanity gate needs root; failure surfaces
minutes later), no host-arch check (x86_64 multiarch paths hardcoded — an
aarch64 host dies with a misleading "loader missing"), `ldconfig -r` failure
silenced, no recorded manifest (tool versions not identifiable).
**Fix**: EUID + `uname -m` gates, loud ldconfig warning, write
`/opt/seed/manifest.txt` (deb list from filenames, rustc version, host,
date) into the tarball, write the sha256 sidecar (D4).

### D13 — initramfs.sh scratch in `$PWD` + unguarded option values (LOW)
`WORK="$PWD/.initramfs-build"` litters the repo / collides between runs;
`--root` without a value dies with `set -u` noise. **Fix**: `mktemp -d`,
explicit argument-count guards.

### D14 — Documentation drift (MED)
README claims "Every recipe carries a sha256" (false: 32 GUI placeholders);
the seed trust boundary (prebuilt Debian .debs + rustup binaries — the
bootstrap is NOT source-only) is not explicit; no stage-contract table, no
invalidation/resume documentation, no test inventory, no
verified-vs-intended boundary. **Fix**: rewrite the affected README sections
+ CHANGELOG entry; keep claims aligned with what tests actually prove.

### D15 — ensure-chroot-mounts.sh silent resolv.conf copy failure (LOW)
`cp -L ... || true` with no fallback when the copy fails → DNS dead inside
the chroot with confusing downstream errors. **Fix**: verify the result,
else write the public-resolver fallback.

### D16 — list-stages cannot distinguish failed / stale / pending (LOW)
**Fix**: per-stage failure markers written by the build-all trap, cleared on
that stage's later success; `--list-stages` reports `FAILED`/`stale (inputs
changed)`/`pending` separately.

### Non-defects (verified, do not "fix")
- `TERM="$TERM"` under `set -u` in stage2/3: bash self-defaults TERM=dumb
  (verified empirically) — safe.
- mkiso `${EXCL[@]:+-e "${EXCL[@]}"}` expansion: verified word-split-correct.
- deps resolution walking only `depends.build`: correct for a source-based
  full-graph build (run deps only matter at install time).
- stage3's stdin heredoc: nothing inside reads stdin today; extraction to
  stage3-inner.sh is done for bash -n/shellcheck coverage and consistency,
  not to fix a live bug.

## Implementation order

1. `bootstrap/sync-repo.sh` (new) + use in stage1/2/3 (D7)
2. `bootstrap/build-all.sh`: input sidecars + cascade (D1), from-stage force
   (D2), lock (D3), seed-adoption validation (D4), wipe guard (D8), failure
   markers (D16), preflight additions (zstd/unshare/pivot_root for 1-3,
   xorriso for iso), log header with tool versions
3. `bootstrap/stage1.sh`: seed verification (D4), sync-repo
4. `bootstrap/stage2.sh` + `stage2-inner.sh`: conditional env.sh + cargo
   guard (D5), remove the readline hack (D6), DPM_BIN override
5. `bootstrap/stage3.sh` + new `stage3-inner.sh`: extraction, derived
   toolchain order (D9), self-hosting verification (D10)
6. `bootstrap/final-root.sh`: `verify_final_root_no_seed_refs` helper (D10)
7. `bootstrap/mkiso.sh`: xorriso fail-fast + structural validation (D11);
   `bootstrap/initramfs.sh` fixes (D13)
8. `bootstrap/seed/build-seed.sh`: gates, manifest, sidecar (D12)
9. `bootstrap/ensure-chroot-mounts.sh`: resolv.conf fallback (D15)
10. Tests: extend `scripts/test-build-all-mock.sh` (input invalidation, lock,
    legacy stamps, seed validation, wipe guard, sidecars); new
    `scripts/test-mkiso.sh` (structural validation, stubbed); extend
    `scripts/test-final-root.sh` (seed-ref ELF check)
11. CI: wire the new test; docs + CHANGELOG (D14)

## Acceptance criteria

- All existing checks stay green (no behavior regression); new regression
  tests fail on the pristine tree's defects and pass after the fix.
- `--with-gui`/`--stage3-world`/`--vol-id`/recipe changes invalidate exactly
  the affected stages + downstream; unrelated stamps survive.
- A stage that runs always invalidates downstream stamps.
- `--dry-run` still writes nothing (state dir untouched).
- `--wipe` refuses FHS roots/ancestors; lock rejects concurrent builds.
- Seed adoption is checksum-verified when a sidecar exists; stage1 verifies
  before unpacking.
- Stage2 can re-run after stage3 (no seed, installed dpm reused).
- Stage3 asserts self-hosting with real checks (compile+run, db ownership,
  ELF /opt scan) — failing any of them fails the stage.
- mkiso structurally validates the ISO contents.
- Docs match the implementation; the seed trust boundary and every
  unverified claim are stated.

## Architectural limitations (documented, not fixed here)

- No source-tarball cache for recipe builds (each rebuild re-downloads);
  per-package retry exists, full cache is future work.
- ISO is structurally validated but never boot-tested in this environment
  (no KVM); bootability is asserted only by the author's VM runs.
- recipes/gui sha256 placeholders mean WITH_GUI=1 fails loudly at
  verification until `scripts/fill-sha256.py` pins them (by design).
- Stage scripts other than build-all keep no state: running them manually
  bypasses stamps/inputs (documented).
