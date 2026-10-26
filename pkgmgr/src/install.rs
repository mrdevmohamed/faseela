//! Install / remove / rollback operations against a target root.
//!
//! Atomicity model:
//! * every archive is extracted into a hidden staging dir, verified against
//!   the local database, then moved into place — a failed install leaves the
//!   previous system state untouched
//! * database writes go through temp-file + rename (crash-safe)
//! * replaced packages leave an undo record (`/var/lib/dpm/undo/<name>`) and
//!   their archive in the package cache (`/var/cache/dpm`) so `dpm rollback`
//!   can restore the previous version
//! * files under /etc that would change content are installed as
//!   `<path>.dpm-new` instead of overwriting local modifications

use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::archive;
use crate::db::{Db, Entry};
use crate::sign;

/// Install a `.dpm.tar.zst` archive into `root`.
///
/// * `force`            — overwrite files owned by other packages
/// * `allow_unsigned`   — accept unsigned archives when trust keys exist
/// * `key`              — verify signature against this pubkey instead of the trust store
/// * `reason`           — "explicit" | "dependency" | "keep" (preserve old reason)
pub fn install_archive(
    archive_path: &Path,
    root: &Path,
    force: bool,
    allow_unsigned: bool,
    key: Option<&Path>,
    reason: &str,
) -> Result<Entry> {
    let db = Db::new(root);

    // ---- signature policy (before touching anything) ----------------------
    sign::verify_for_install(archive_path, root, key, allow_unsigned)?;

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = root.join(".dpm").join(format!("tmp-{stamp}"));
    std::fs::create_dir_all(&tmp)?;
    // remove the staging dir on every exit path (errors included)
    struct TmpGuard(PathBuf);
    impl Drop for TmpGuard {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _tmp_guard = TmpGuard(tmp.clone());

    let extracted = archive::extract(archive_path, &tmp)?;
    let info = archive::parse_pkginfo(&extracted.pkginfo)?;
    let name = info.get("pkgname").cloned().unwrap_or_default();
    let version = info.get("pkgver").cloned().unwrap_or_default();
    let rel: u32 = info.get("pkgrel").and_then(|v| v.parse().ok()).unwrap_or(1);
    let arch = info.get("arch").cloned().unwrap_or_default();
    let size: u64 = info.get("size").and_then(|v| v.parse().ok()).unwrap_or(0);
    let run: Vec<String> = info
        .get("rundeps")
        .map(|s| s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect())
        .unwrap_or_default();

    // ---- current state of this package (if this is an upgrade/reinstall) ---
    let old = db.entry(&name)?;
    let old_files = match &old {
        Some(e) => db.files(&e.name)?,
        None => Vec::new(),
    };
    let is_upgrade = old.is_some();

    // ---- conflict check against the database ------------------------------
    let staged_files = list_staged_files(&tmp)?;
    let owners = db.file_owners()?;
    if !force {
        let mut conflicts: Vec<String> = Vec::new();
        for f in &staged_files {
            // directories merge silently across packages — never a conflict
            // (every distro has several packages owning /etc or /usr)
            let p = tmp.join(f.trim_start_matches('/'));
            if std::fs::symlink_metadata(&p).map(|m| m.is_dir()).unwrap_or(false) {
                continue;
            }
            if let Some(owner) = owners.get(f) {
                if owner != &name {
                    conflicts.push(format!("{f} (owned by {owner})"));
                }
            }
        }
        if !conflicts.is_empty() {
            let _ = std::fs::remove_dir_all(&tmp);
            bail!(
                "file conflicts installing {}:\n  {}\n(use --force to override)",
                name,
                conflicts.iter().take(20).cloned().collect::<Vec<_>>().join("\n  ")
            );
        }
    }

    // ---- hash the staged /etc files (baseline for config protection) ---------
    let staged_hashes = hash_staged_etc(&tmp)?;

    // ---- remember the previous version for rollback -------------------------
    if let Some(prev) = &old {
        save_undo(&db, root, prev)?;
    }
    let old_hashes = match &old {
        Some(e) => db.hashes(&e.name)?,
        None => std::collections::HashMap::new(),
    };

    // ---- keep a copy of the archive in the package cache --------------------
    cache_archive(archive_path, root)?;
    if is_upgrade {
        println!(
            "dpm: upgrading {} {} -> {}-{}-{}",
            name,
            old.as_ref().map(|e| e.version_full()).unwrap_or_default(),
            name,
            version,
            rel
        );
    }

    // ---- move staged tree into the root -------------------------------------
    let mut diverted: Vec<(String, String)> = Vec::new(); // (orig, diverted)
    let mut tx = Tx::new(root, root.join(".dpm").join(format!("bak-{stamp}")));
    if let Err(e) = move_tree(&tmp, root, root, &old_hashes, &mut diverted, &mut tx) {
        tx.rollback();
        return Err(e);
    }
    let _ = std::fs::remove_dir_all(&tmp);
    for (orig, new) in &diverted {
        println!("dpm: NOTE: installed {new} (local {orig} changed — merge manually)");
    }

    // ---- delete files that disappeared between the two versions -------------
    let mut obsolete_dirs: Vec<PathBuf> = Vec::new();
    if !old_files.is_empty() {
        let new_set: HashSet<&String> = staged_files.iter().collect();
        let mut obsolete: Vec<&String> = old_files
            .iter()
            .filter(|f| !new_set.contains(*f))
            .filter(|f| owners.get(*f).map(|o| o == &name).unwrap_or(false))
            .collect();
        obsolete.sort_by_key(|f| std::cmp::Reverse(f.len()));
        for f in obsolete {
            let p = root.join(f.trim_start_matches('/'));
            match std::fs::symlink_metadata(&p) {
                // directories are removed after the commit (only if empty)
                Ok(md) if md.is_dir() => obsolete_dirs.push(p),
                // files are moved into the undo journal, not deleted yet
                Ok(_) => {
                    let _ = tx.remove(&p);
                }
                Err(_) => {}
            }
        }
    }

    // ---- register in db (atomic: temp file + rename) -------------------------
    let reason = match reason {
        "keep" => old.as_ref().map(|o| o.reason.clone()).unwrap_or_else(|| "explicit".into()),
        r => r.to_string(),
    };
    let entry = Entry {
        name: name.clone(),
        version: version.clone(),
        rel,
        arch: arch.clone(),
        reason,
        run,
        install_date: stamp as u64,
        size,
    };
    let hooks = match archive::read_hooks(archive_path) {
        Ok(h) => h,
        Err(e) => {
            tx.rollback();
            return Err(e);
        }
    };
    if let Err(e) = db.add(&entry, &staged_files, &staged_hashes) {
        // files and db must agree: put the previous state back
        tx.rollback();
        return Err(e);
    }
    // point of no return: drop the undo journal, then tidy empty old dirs
    tx.commit();
    for d in &obsolete_dirs {
        let _ = std::fs::remove_dir(d);
    }

    // ---- hooks ---------------------------------------------------------------
    if let Err(e) = save_hooks(&db, &name, &hooks) {
        eprintln!("dpm: warning: could not store hooks for {name}: {e:#}");
    }
    let (label, script) = if is_upgrade {
        ("post_upgrade", hooks.post_install.as_str())
    } else {
        ("post_install", hooks.post_install.as_str())
    };
    run_hook(label, script, root)?;

    if is_upgrade {
        println!("dpm: upgraded {} (previous version kept for rollback)", entry.version_full());
    } else {
        println!("dpm: installed {} into {}", entry.version_full(), root.display());
    }
    Ok(entry)
}

/// Restore a package to the version recorded in its undo log
/// (`/var/lib/dpm/undo/<name>`), using the cached archive of that version.
/// Works after an upgrade (goes one version back — ping-pong capable) and
/// after a remove (reinstalls the removed version).
pub fn rollback(name: &str, root: &Path) -> Result<()> {
    let db = Db::new(root);
    crate::db::check_name(name)?;
    let undo_dir = root.join("var/lib/dpm/undo").join(name);
    let desc_path = undo_dir.join("desc");
    if !desc_path.exists() {
        bail!("no undo record for `{name}` — nothing to roll back");
    }
    let prev: Entry = toml::from_str(&std::fs::read_to_string(&desc_path)?)
        .context("corrupt undo record")?;

    match db.entry(name)? {
        Some(cur) if cur.version_full() == prev.version_full() => {
            bail!("`{name}` is already at {} — nothing to roll back", cur.version_full());
        }
        _ => {}
    }

    let archive_path = root
        .join("var/cache/dpm")
        .join(format!("{}.dpm.tar.zst", prev.version_full()));
    if !archive_path.exists() {
        bail!(
            "cached archive {} is missing — cannot roll back",
            archive_path.display()
        );
    }

    println!(
        "dpm: rolling back {} -> {}",
        db.entry(name)?.map(|e| e.version_full()).unwrap_or_else(|| "(removed)".into()),
        prev.version_full()
    );
    // cache content was verified when it was first installed
    install_archive(&archive_path, root, false, true, None, "keep")?;
    Ok(())
}

#[allow(dead_code)] // convenience wrapper over remove_with
pub fn remove(name: &str, root: &Path) -> Result<()> {
    remove_with(name, root, false)
}

/// Remove a package. Without `force`, refuse when another installed package
/// lists it in its run-time dependencies.
///
/// The removal is journaled like the install: files move into a hidden
/// `.dpm/rm-<stamp>/` dir first (deepest first) and are restored if the db
/// update fails; the db entry is only dropped once every file has been moved.
/// A failure to move any file aborts the removal instead of silently
/// leaving a half-removed package behind.
pub fn remove_with(name: &str, root: &Path, force: bool) -> Result<()> {
    let db = Db::new(root);
    let entry = match db.entry(name)? {
        Some(e) => e,
        None => bail!("`{name}` is not installed"),
    };

    if !force {
        let dependents: Vec<String> = db
            .installed()?
            .into_iter()
            .filter(|e| e.name != name && e.run.iter().any(|r| r == name))
            .map(|e| e.name)
            .collect();
        if !dependents.is_empty() {
            bail!(
                "cannot remove `{name}`: required by {}\n(use --force to remove anyway)",
                dependents.join(", ")
            );
        }
    }

    // undo record so `dpm rollback` can reinstall this exact version
    save_undo(&db, root, &entry)?;

    let hooks = load_hooks(&db, name);
    run_hook("pre_remove", &hooks.pre_remove, root)?;

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut files = db.files(name)?;
    files.sort_by_key(|f| std::cmp::Reverse(f.len()));
    let mut tx = Tx::new(root, root.join(".dpm").join(format!("rm-{stamp}")));
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut move_err: Option<anyhow::Error> = None;
    for f in &files {
        let p = root.join(f.trim_start_matches('/'));
        match std::fs::symlink_metadata(&p) {
            // directories are removed after the commit (only if empty)
            Ok(md) if md.is_dir() => dirs.push(p),
            // a reversible delete: the file moves into the rm- journal
            Ok(_) => {
                if let Err(e) = tx.remove(&p) {
                    move_err = Some(e);
                    break;
                }
            }
            Err(_) => {} // already gone — nothing to undo for it
        }
    }
    if let Some(e) = move_err {
        tx.rollback();
        return Err(e);
    }
    if let Err(e) = db.remove(name) {
        // files and db must agree: put everything back
        tx.rollback();
        return Err(e);
    }
    tx.commit();
    for d in &dirs {
        let _ = std::fs::remove_dir(d);
    }

    run_hook("post_remove", &hooks.post_remove, root)?;
    println!(
        "dpm: removed {} from {} (rollback available via cached archive)",
        entry.version_full(),
        root.display()
    );
    Ok(())
}

/// Copy an archive into `<root>/var/cache/dpm` (hardlink when possible).
/// Also keeps the detached signature next to it when one exists.
pub fn cache_archive(archive_path: &Path, root: &Path) -> Result<PathBuf> {
    let dir = root.join("var/cache/dpm");
    std::fs::create_dir_all(&dir)?;
    let dest = dir.join(archive_path.file_name().unwrap_or_default());
    if !dest.exists()
        && std::fs::hard_link(archive_path, &dest).is_err() {
            std::fs::copy(archive_path, &dest)
                .with_context(|| format!("cache {}", archive_path.display()))?;
        }
    let sig = sign::sig_path_for(archive_path);
    if sig.exists() {
        let sig_dest = sign::sig_path_for(&dest);
        if !sig_dest.exists() {
            let _ = std::fs::hard_link(&sig, &sig_dest)
                .or_else(|_| std::fs::copy(&sig, &sig_dest).map(|_| ()));
        }
    }
    Ok(dest)
}

fn save_undo(db: &Db, root: &Path, prev: &Entry) -> Result<()> {
    let dir = root.join("var/lib/dpm/undo").join(&prev.name);
    std::fs::create_dir_all(&dir)?;
    let desc = toml::to_string_pretty(prev)?;
    // write+rename so an interrupted save can't corrupt the record
    let tmp = dir.join(".desc.tmp");
    std::fs::write(&tmp, desc)?;
    std::fs::rename(&tmp, dir.join("desc"))?;
    let files = db.files(&prev.name)?;
    let ftmp = dir.join(".files.tmp");
    std::fs::write(&ftmp, files.join("\n") + "\n")?;
    std::fs::rename(&ftmp, dir.join("files"))?;
    Ok(())
}

fn list_staged_files(staged: &Path) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for e in walkdir::WalkDir::new(staged).sort_by_file_name() {
        let e = e?;
        let rel = e.path().strip_prefix(staged)?;
        if rel.as_os_str().is_empty() {
            continue;
        }
        out.push(format!("/{}", rel.display()));
    }
    Ok(out)
}

/// Undo journal for `move_tree`: every file that replaces an existing one is
/// first moved to a backup dir, every newly created file is remembered, so a
/// failure half-way through can restore the previous state (all-or-nothing
/// file placement).
struct Tx {
    root: PathBuf,
    bak_root: PathBuf,
    created: Vec<PathBuf>,
    replaced: Vec<(PathBuf, PathBuf)>, // (destination, backup)
}

impl Tx {
    fn new(root: &Path, bak_root: PathBuf) -> Self {
        Tx { root: root.to_path_buf(), bak_root, created: Vec::new(), replaced: Vec::new() }
    }

    /// Move `from` to `to`, backing up whatever `to` currently is.
    fn place(&mut self, from: &Path, to: &Path) -> Result<()> {
        if std::fs::symlink_metadata(to).is_ok() {
            let rel = to.strip_prefix(&self.root)?;
            let bak = self.bak_root.join(rel);
            if let Some(parent) = bak.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::rename(to, &bak)
                .with_context(|| format!("back up {}", to.display()))?;
            self.replaced.push((to.to_path_buf(), bak));
        } else {
            self.created.push(to.to_path_buf());
        }
        std::fs::rename(from, to)
            .with_context(|| format!("move {} -> {}", from.display(), to.display()))
    }

    /// Move an existing path into the backup dir (a reversible delete).
    fn remove(&mut self, path: &Path) -> Result<()> {
        let rel = path.strip_prefix(&self.root)?;
        let bak = self.bak_root.join(rel);
        if let Some(parent) = bak.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::rename(path, &bak).with_context(|| format!("remove {}", path.display()))?;
        self.replaced.push((path.to_path_buf(), bak));
        Ok(())
    }

    /// Best-effort restore of the pre-install state.
    fn rollback(&mut self) {
        for p in self.created.iter().rev() {
            let _ = std::fs::remove_file(p);
        }
        for (dest, bak) in self.replaced.iter().rev() {
            let _ = std::fs::remove_file(dest);
            let _ = std::fs::rename(bak, dest);
        }
        let _ = std::fs::remove_dir_all(&self.bak_root);
    }

    fn commit(self) {
        let _ = std::fs::remove_dir_all(&self.bak_root);
    }
}

/// Recursively move `src` into `dst`, merging directories.
///
/// Config protection (pacman-style): a file under `<root>/etc` that would
/// change content is only overwritten in place when the on-disk copy still
/// matches the hash recorded at install time (i.e. the admin never touched
/// it). Locally modified configs are preserved and the new version lands
/// next to them as `<path>.dpm-new` (recorded in `diverted`).
fn move_tree(
    src: &Path,
    dst: &Path,
    root: &Path,
    old_hashes: &std::collections::HashMap<String, String>,
    diverted: &mut Vec<(String, String)>,
    tx: &mut Tx,
) -> Result<()> {
    for entry in std::fs::read_dir(src).with_context(|| format!("read {}", src.display()))? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        let is_dir = from.is_dir() && !std::fs::symlink_metadata(&from)?.is_symlink();
        if is_dir {
            std::fs::create_dir_all(&to)?;
            // carry the staged directory's mode over: create_dir_all applies
            // the umask, which would strip e.g. the sticky bit from /tmp
            let md = std::fs::symlink_metadata(&from)?;
            let _ = std::fs::set_permissions(&to, md.permissions());
            move_tree(&from, &to, root, old_hashes, diverted, tx)?;
        } else {
            if let Some(parent) = to.parent() {
                std::fs::create_dir_all(parent)?;
            }
            if contents_differ(&from, &to) && is_under_etc(&to, root) {
                let pkgpath = format!("/{}", to.strip_prefix(root)?.display());
                let admin_modified = match old_hashes.get(&pkgpath) {
                    // baseline exists: divert only if the disk copy drifted
                    Some(h) => path_hash(&to).as_deref() != Some(h.as_str()),
                    // no baseline (legacy db entry): be safe, divert
                    None => true,
                };
                if admin_modified {
                    let mut alt = to.clone().into_os_string();
                    alt.push(".dpm-new");
                    tx.place(&from, Path::new(&alt))?;
                    diverted.push((to.to_string_lossy().to_string(), alt.to_string_lossy().to_string()));
                } else {
                    tx.place(&from, &to)?;
                }
            } else {
                tx.place(&from, &to)?;
            }
        }
    }
    Ok(())
}

fn is_under_etc(p: &Path, root: &Path) -> bool {
    // p is an absolute path inside the target root; compare against the
    // root prefix so a root dir literally named ".../etc/..." can't match
    match p.strip_prefix(root) {
        Ok(rel) => rel
            .components()
            .next()
            .map(|c| c.as_os_str() == "etc")
            .unwrap_or(false),
        Err(_) => false,
    }
}

/// sha256 map for every /etc file in the staging tree: path (as it will be
/// on the target, e.g. "/etc/foo.conf") -> hash. Symlinks hash their target
/// string so the baseline stays stable across identical reinstalls.
fn hash_staged_etc(staged: &Path) -> Result<std::collections::HashMap<String, String>> {
    let mut out = std::collections::HashMap::new();
    for e in walkdir::WalkDir::new(staged).sort_by_file_name() {
        let e = e?;
        let rel = e.path().strip_prefix(staged)?;
        if rel.as_os_str().is_empty() || rel.components().next().map(|c| c.as_os_str() != "etc").unwrap_or(true) {
            continue;
        }
        let pkgpath = format!("/{}", rel.display());
        if let Some(h) = path_hash(e.path()) {
            out.insert(pkgpath, h);
        }
    }
    Ok(out)
}

/// sha256 of a file's bytes; for symlinks, of the target path string.
fn path_hash(p: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let md = std::fs::symlink_metadata(p).ok()?;
    let mut h = Sha256::new();
    if md.is_symlink() {
        let t = std::fs::read_link(p).ok()?;
        h.update(t.to_string_lossy().as_bytes());
    } else if md.is_file() {
        let bytes = std::fs::read(p).ok()?;
        h.update(&bytes);
    } else {
        return None;
    }
    Some(hex::encode(h.finalize()))
}

fn contents_differ(staged: &Path, dest: &Path) -> bool {
    let (ma, mb) = match (std::fs::symlink_metadata(staged), std::fs::symlink_metadata(dest)) {
        (Ok(a), Ok(b)) => (a, b),
        // destination missing -> nothing to protect
        _ => return false,
    };
    match (ma.is_symlink(), mb.is_symlink()) {
        (true, true) => std::fs::read_link(staged).ok() != std::fs::read_link(dest).ok(),
        (true, false) | (false, true) => true, // type change
        (false, false) => {
            if ma.is_dir() || mb.is_dir() {
                true // dir/file flip — cannot compare
            } else {
                match (std::fs::read(staged), std::fs::read(dest)) {
                    (Ok(a), Ok(b)) => a != b,
                    _ => true, // unreadable -> be safe, divert
                }
            }
        }
    }
}

fn hooks_path(db: &Db, name: &str) -> PathBuf {
    db.local_dir().join(name).join("hooks")
}

/// Persist a package's hooks next to its db entry (needed at remove time).
fn save_hooks(db: &Db, name: &str, hooks: &archive::Hooks) -> Result<()> {
    let p = hooks_path(db, name);
    if hooks.is_empty() {
        let _ = std::fs::remove_file(&p);
        return Ok(());
    }
    let tmp = p.with_extension("tmp");
    std::fs::write(&tmp, toml::to_string(hooks)?)?;
    std::fs::rename(&tmp, &p)?;
    Ok(())
}

fn load_hooks(db: &Db, name: &str) -> archive::Hooks {
    std::fs::read_to_string(hooks_path(db, name))
        .ok()
        .and_then(|s| toml::from_str(&s).ok())
        .unwrap_or_default()
}

extern "C" {
    // part of libc, which std already links (same approach as lock.rs)
    fn geteuid() -> u32;
}

/// True when this process runs as root. Uses the effective uid directly:
/// it must not depend on /proc being mounted (it is not inside a fresh chroot).
fn running_as_root() -> bool {
    unsafe { geteuid() == 0 }
}

/// Hooks run either on the live system (`--root /`) or, when dpm runs as
/// root and the target has a shell, inside a chroot of the target. Anything
/// else is skipped: executing a package's script on the host while
/// installing into another root would run it on the wrong filesystem.
/// (No /proc or /dev is mounted in the chroot.)
fn run_hook(label: &str, script: &str, root: &Path) -> Result<()> {
    if script.trim().is_empty() {
        return Ok(());
    }
    let live = std::fs::canonicalize(root)
        .map(|p| p == Path::new("/"))
        .unwrap_or(false);
    let status = if live {
        println!("dpm: running {label} hook");
        Command::new("bash")
            .args(["-e", "-c", script])
            .env("DPM_ROOT", root)
            .env(crate::lock::HELD_ENV, "1") // we hold the db lock; nested dpm must not wait for it
            .status()?
    } else {
        let shell = ["/bin/bash", "/bin/sh"]
            .into_iter()
            .find(|sh| root.join(sh.trim_start_matches('/')).exists());
        match shell {
            Some(sh) if running_as_root() => {
                println!("dpm: running {label} hook in chroot {}", root.display());
                Command::new("chroot")
                    .arg(root)
                    .args([sh, "-e", "-c", script])
                    .env("DPM_ROOT", "/")
                    .env(crate::lock::HELD_ENV, "1")
                    .status()?
            }
            _ => {
                println!("dpm: note: skipping {label} hook (--root is not / and no chroot possible)");
                return Ok(());
            }
        }
    };
    if !status.success() {
        bail!("{label} hook failed");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archive;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("dpm-install-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Build a fake package archive with the given files.
    fn make_pkg(dir: &Path, name: &str, version: &str, files: &[(&str, &[u8])]) -> PathBuf {
        let staging = dir.join(format!("staging-{name}-{version}"));
        std::fs::create_dir_all(&staging).unwrap();
        for (p, body) in files {
            let full = staging.join(p.trim_start_matches('/'));
            std::fs::create_dir_all(full.parent().unwrap()).unwrap();
            std::fs::write(full, body).unwrap();
        }
        let pkginfo = format!(
            "pkgname = {name}\npkgver = {version}\npkgrel = 1\narch = x86_64\nrundeps = \nsize = 1\n"
        );
        let out = dir.join(format!("{name}-{version}-1.dpm.tar.zst"));
        archive::create(&staging, &pkginfo, &out).unwrap();
        out
    }

    #[test]
    fn upgrade_updates_files_and_removes_obsolete() {
        let base = tmpdir("upgrade");
        let root = base.join("root");
        let v1 = make_pkg(&base, "demo", "1.0", &[
            ("/usr/bin/demo", b"v1"),
            ("/usr/lib/demo/old.so", b"legacy"),
        ]);
        let v2 = make_pkg(&base, "demo", "2.0", &[
            ("/usr/bin/demo", b"v2"),
        ]);

        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/demo")).unwrap(), b"v1");

        install_archive(&v2, &root, false, true, None, "explicit").unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/demo")).unwrap(), b"v2");
        // obsolete file was removed
        assert!(!root.join("usr/lib/demo/old.so").exists());

        let db = Db::new(&root);
        let e = db.entry("demo").unwrap().unwrap();
        assert_eq!(e.version, "2.0");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn upgrade_protects_modified_etc_files() {
        let base = tmpdir("etcnew");
        let root = base.join("root");
        let v1 = make_pkg(&base, "srv", "1.0", &[
            ("/etc/srv.conf", b"original\n"),
            ("/usr/bin/srv", b"bin1"),
        ]);
        let v2 = make_pkg(&base, "srv", "2.0", &[
            ("/etc/srv.conf", b"changed upstream\n"),
            ("/usr/bin/srv", b"bin2"),
        ]);

        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        // admin edits the config
        std::fs::write(root.join("etc/srv.conf"), b"locally edited\n").unwrap();

        install_archive(&v2, &root, false, true, None, "explicit").unwrap();

        // local edit preserved, upstream change diverted to .dpm-new
        assert_eq!(std::fs::read(root.join("etc/srv.conf")).unwrap(), b"locally edited\n");
        let diverted = root.join("etc/srv.conf.dpm-new");
        assert!(diverted.exists(), ".dpm-new diversion missing");
        assert_eq!(std::fs::read(&diverted).unwrap(), b"changed upstream\n");

        // non-etc files are replaced without diversion
        assert_eq!(std::fs::read(root.join("usr/bin/srv")).unwrap(), b"bin2");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn unmodified_etc_files_upgrade_in_place() {
        let base = tmpdir("etcsame");
        let root = base.join("root");
        let v1 = make_pkg(&base, "srv", "1.0", &[("/etc/srv.conf", b"same\n")]);
        let v2 = make_pkg(&base, "srv", "2.0", &[("/etc/srv.conf", b"same\n")]);
        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        install_archive(&v2, &root, false, true, None, "explicit").unwrap();
        assert!(root.join("etc/srv.conf").exists());
        assert!(!root.join("etc/srv.conf.dpm-new").exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn upstream_config_change_without_local_edits_overwrites_in_place() {
        // admin never touched the config (hash baseline matches) -> a version
        // bump that changes /etc content replaces it directly, no diversion
        let base = tmpdir("etcupstream");
        let root = base.join("root");
        let v1 = make_pkg(&base, "srv", "1.0", &[("/etc/srv.conf", b"stock v1\n")]);
        let v2 = make_pkg(&base, "srv", "2.0", &[("/etc/srv.conf", b"stock v2\n")]);
        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        install_archive(&v2, &root, false, true, None, "explicit").unwrap();
        assert_eq!(std::fs::read(root.join("etc/srv.conf")).unwrap(), b"stock v2\n");
        assert!(!root.join("etc/srv.conf.dpm-new").exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn hashes_baseline_missing_falls_back_to_diversion() {
        // simulate a legacy db entry (installed before hash tracking): the
        // on-disk config has no baseline -> safe default is diversion
        let base = tmpdir("etchash");
        let root = base.join("root");
        let v1 = make_pkg(&base, "srv", "1.0", &[("/etc/srv.conf", b"v1\n")]);
        let v2 = make_pkg(&base, "srv", "2.0", &[("/etc/srv.conf", b"v2\n")]);
        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        // wipe the baseline to emulate a pre-v0.5 database
        let db = Db::new(&root);
        std::fs::remove_file(db.local_dir().join("srv/hashes")).unwrap();
        install_archive(&v2, &root, false, true, None, "explicit").unwrap();
        assert_eq!(std::fs::read(root.join("etc/srv.conf")).unwrap(), b"v1\n");
        assert_eq!(std::fs::read(root.join("etc/srv.conf.dpm-new")).unwrap(), b"v2\n");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn rollback_reverts_upgrade_and_ping_pongs() {
        let base = tmpdir("rollback");
        let root = base.join("root");
        let v1 = make_pkg(&base, "demo", "1.0", &[("/usr/bin/demo", b"v1")]);
        let v2 = make_pkg(&base, "demo", "2.0", &[("/usr/bin/demo", b"v2")]);

        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        install_archive(&v2, &root, false, true, None, "explicit").unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/demo")).unwrap(), b"v2");

        // roll back to 1.0
        rollback("demo", &root).unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/demo")).unwrap(), b"v1");
        let db = Db::new(&root);
        assert_eq!(db.entry("demo").unwrap().unwrap().version, "1.0");

        // ping-pong: undo record now points at 2.0
        rollback("demo", &root).unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/demo")).unwrap(), b"v2");

        // and back again — the undo log alternates indefinitely
        rollback("demo", &root).unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/demo")).unwrap(), b"v1");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn rollback_after_remove_reinstalls() {
        let base = tmpdir("rmrollback");
        let root = base.join("root");
        let v1 = make_pkg(&base, "gone", "1.0", &[("/usr/bin/gone", b"x")]);
        install_archive(&v1, &root, false, true, None, "explicit").unwrap();
        remove("gone", &root).unwrap();
        assert!(!root.join("usr/bin/gone").exists());
        rollback("gone", &root).unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/gone")).unwrap(), b"x");
        let db = Db::new(&root);
        assert!(db.entry("gone").unwrap().is_some());

        // undo record now equals the installed version -> nothing to roll back
        assert!(rollback("gone", &root).is_err());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn reason_keep_preserves_explicit_flag() {
        let base = tmpdir("reason");
        let root = base.join("root");
        let v1 = make_pkg(&base, "r", "1.0", &[("/usr/bin/r", b"a")]);
        let v2 = make_pkg(&base, "r", "2.0", &[("/usr/bin/r", b"b")]);
        install_archive(&v1, &root, false, true, None, "dependency").unwrap();
        let db = Db::new(&root);
        assert_eq!(db.entry("r").unwrap().unwrap().reason, "dependency");
        install_archive(&v2, &root, false, true, None, "keep").unwrap();
        assert_eq!(db.entry("r").unwrap().unwrap().reason, "dependency");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn remove_refuses_when_required_by_another_package() {
        let base = tmpdir("revdeps");
        let root = base.join("root");
        let lib = make_pkg(&base, "libx", "1.0", &[("/usr/lib/libx", b"l")]);
        let st = base.join("st-app");
        std::fs::create_dir_all(st.join("usr/bin")).unwrap();
        std::fs::write(st.join("usr/bin/app"), b"a").unwrap();
        let app = base.join("app-1.0-1.dpm.tar.zst");
        archive::create(
            &st,
            "pkgname = app\npkgver = 1.0\npkgrel = 1\narch = x86_64\nrundeps = libx\nsize = 1\n",
            &app,
        )
        .unwrap();
        install_archive(&lib, &root, false, true, None, "explicit").unwrap();
        install_archive(&app, &root, false, true, None, "explicit").unwrap();

        assert!(remove("libx", &root).is_err());
        assert!(root.join("usr/lib/libx").exists());
        remove_with("libx", &root, true).unwrap();
        assert!(!root.join("usr/lib/libx").exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn tx_rollback_restores_replaced_and_removes_created() {
        let base = tmpdir("tx");
        let root = base.join("root");
        std::fs::create_dir_all(root.join("usr/bin")).unwrap();
        std::fs::write(root.join("usr/bin/old"), b"orig").unwrap();
        let stage = base.join("stage");
        std::fs::create_dir_all(&stage).unwrap();
        std::fs::write(stage.join("new-content"), b"new").unwrap();
        std::fs::write(stage.join("fresh"), b"fresh").unwrap();

        let mut tx = Tx::new(&root, base.join("bak"));
        tx.place(&stage.join("new-content"), &root.join("usr/bin/old")).unwrap();
        tx.place(&stage.join("fresh"), &root.join("usr/bin/fresh")).unwrap();
        assert_eq!(std::fs::read(root.join("usr/bin/old")).unwrap(), b"new");

        tx.rollback();
        assert_eq!(std::fs::read(root.join("usr/bin/old")).unwrap(), b"orig");
        assert!(!root.join("usr/bin/fresh").exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn tx_remove_is_reversible() {
        let base = tmpdir("tx-remove");
        let root = base.join("root");
        std::fs::create_dir_all(root.join("etc")).unwrap();
        std::fs::write(root.join("etc/gone"), b"keep me").unwrap();
        let mut tx = Tx::new(&root, base.join("bak"));
        tx.remove(&root.join("etc/gone")).unwrap();
        assert!(!root.join("etc/gone").exists());
        tx.rollback();
        assert_eq!(std::fs::read(root.join("etc/gone")).unwrap(), b"keep me");
        let _ = std::fs::remove_dir_all(&base);
    }
}
