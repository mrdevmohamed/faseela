//! Source fetching (via external `curl`, present in the bootstrap seed) and
//! sha256 verification.

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn sha256_of_file(path: &Path) -> Result<String> {
    let mut f = std::fs::File::open(path)
        .with_context(|| format!("cannot open {} for hashing", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn verify_sha256(path: &Path, expected: &str) -> Result<()> {
    if expected.trim().is_empty() {
        bail!("missing sha256 for {} — refusing to build unverified source", path.display());
    }
    let got = sha256_of_file(path)?;
    if got != expected.trim().to_lowercase() {
        bail!(
            "sha256 mismatch for {}:\n  expected: {}\n  got:      {}",
            path.display(),
            expected,
            got
        );
    }
    Ok(())
}

/// Download `url` into `dest` using curl (retries + fail on HTTP error).
pub fn download(url: &str, dest: &PathBuf) -> Result<()> {
    let status = Command::new("curl")
        .args(["-fL", "--proto", "=http,https", "--proto-redir", "=https",
               "--retry", "3", "--connect-timeout", "20", "-o"])
        .arg(dest)
        .arg("--")
        .arg(url)
        .status()
        .context("curl not available (is this running outside the seed?)")?;
    if !status.success() {
        bail!("download failed: {url}");
    }
    Ok(())
}

/// Copy a file or directory tree from the host (for `local:` sources).
pub fn copy_local(src: &Path, dest: &Path) -> Result<()> {
    if src.is_dir() {
        let status = Command::new("cp")
            .args(["-a"])
            .arg(format!("{}/.", src.display()))
            .arg(dest)
            .status()?;
        if !status.success() {
            bail!("failed to copy local source {}", src.display());
        }
    } else {
        std::fs::copy(src, dest).with_context(|| format!("copy {}", src.display()))?;
    }
    Ok(())
}

/// A package repository location: a local directory or an http(s) URL.
///
/// Remote repositories are materialized into a per-URL cache directory under
/// `<root>/var/cache/dpm/remote/` (index fetched fresh, archives cached and
/// sha256-verified), after which the normal upgrade path runs unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RepoRef {
    Local(PathBuf),
    /// Base URL without a trailing slash, e.g. `https://mirror/stable`
    Remote(String),
}

impl RepoRef {
    pub fn parse(s: &str) -> Result<Self> {
        let s = s.trim();
        if s.starts_with("http://") || s.starts_with("https://") {
            Ok(RepoRef::Remote(s.trim_end_matches('/').to_string()))
        } else if s.contains("://") {
            bail!("unsupported repository `{s}` — use http(s):// or a local path");
        } else {
            Ok(RepoRef::Local(PathBuf::from(s)))
        }
    }
}

/// Stable per-URL cache directory: `<root>/var/cache/dpm/remote/<key>`.
/// The key is the first 12 hex chars of sha256(base_url), so the same
/// repository always maps to the same cache and different URLs never clash.
pub fn remote_cache_dir(root: &Path, base_url: &str) -> PathBuf {
    let mut h = Sha256::new();
    h.update(base_url.as_bytes());
    let key = hex::encode(&h.finalize()[..6]);
    root.join("var/cache/dpm/remote").join(key)
}

/// Like `download`, but treats curl's HTTP>=400 exit code as "file absent"
/// and returns `false` instead of failing (used for optional `.sig` sidecars).
pub fn download_opt(url: &str, dest: &Path) -> Result<bool> {
    let status = Command::new("curl")
        .args(["-fsL", "--proto", "=http,https", "--proto-redir", "=https",
               "--retry", "2", "--connect-timeout", "20", "-o"])
        .arg(dest)
        .arg("--")
        .arg(url)
        .status()
        .context("curl not available (is this running outside the seed?)")?;
    match status.code() {
        Some(0) => Ok(true),
        Some(22) => Ok(false), // HTTP >= 400: the file is not there
        _ => bail!("download failed: {url}"),
    }
}

/// The URL itself, then equivalent mirrors for well-known GNU hosts, so one
/// unreachable mirror does not fail the whole build. Content is always
/// checked against the recipe's pinned sha256, so mirrors need no trust.
pub fn candidate_urls(url: &str) -> Vec<String> {
    let mut v = vec![url.to_string()];
    for prefix in [
        "https://mirrors.kernel.org/gnu/",
        "https://ftp.gnu.org/gnu/",
        "https://ftpmirror.gnu.org/",
        "https://mirror.us-midwest-1.nexcess.net/gnu/",
        "https://mirrors.ocf.berkeley.edu/gnu/",
    ] {
        if let Some(rest) = url.strip_prefix(prefix) {
            for alt in [
                "https://ftpmirror.gnu.org/",
                "https://ftp.gnu.org/gnu/",
                "https://mirrors.kernel.org/gnu/",
                "https://mirrors.ocf.berkeley.edu/gnu/",
            ] {
                let u = format!("{alt}{rest}");
                if !v.contains(&u) {
                    v.push(u);
                }
            }
            break;
        }
    }
    v
}

/// Download `url` into `dest` unless a copy is already cached.
/// With `expect_sha256`, a cached copy is reused only after re-verifying it,
/// so a corrupted or truncated cache entry is transparently re-downloaded.
/// The transfer lands in a `.part` sibling first and is renamed atomically.
pub fn download_cached(url: &str, dest: &Path, expect_sha256: Option<&str>) -> Result<()> {
    if dest.exists() {
        match expect_sha256 {
            Some(expected) => {
                if verify_sha256(dest, expected).is_ok() {
                    return Ok(()); // cache hit
                }
                eprintln!("dpm: cached {} failed sha256 — re-downloading", dest.display());
            }
            None => return Ok(()), // unpinned cache hit (index: signature checked separately)
        }
    }
    let tmp = dest.with_extension("part");
    let mut last_err = None;
    for cand in candidate_urls(url) {
        if cand != url {
            eprintln!("dpm: trying alternate mirror {cand}");
        }
        let res = download(&cand, &tmp).and_then(|_| match expect_sha256 {
            Some(e) => verify_sha256(&tmp, e),
            None => Ok(()),
        });
        match res {
            Ok(()) => {
                last_err = None;
                break;
            }
            Err(e) => {
                eprintln!("dpm: {e}");
                let _ = std::fs::remove_file(&tmp);
                last_err = Some(e);
            }
        }
    }
    if let Some(e) = last_err {
        return Err(e);
    }
    std::fs::rename(&tmp, dest)
        .with_context(|| format!("activate cached download {}", dest.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_ref_parses_local_and_remote() {
        assert_eq!(
            RepoRef::parse("/srv/repo").unwrap(),
            RepoRef::Local(PathBuf::from("/srv/repo"))
        );
        assert_eq!(
            RepoRef::parse("repo/").unwrap(),
            RepoRef::Local(PathBuf::from("repo"))
        );
        assert_eq!(
            RepoRef::parse("https://mirror.example.com/stable/").unwrap(),
            RepoRef::Remote("https://mirror.example.com/stable".into())
        );
        assert_eq!(
            RepoRef::parse("http://127.0.0.1:8000").unwrap(),
            RepoRef::Remote("http://127.0.0.1:8000".into())
        );
        assert!(RepoRef::parse("ftp://host/repo").is_err());
    }

    #[test]
    fn gnu_urls_get_fallbacks() {
        let v = candidate_urls("https://mirrors.kernel.org/gnu/screen/screen-5.0.0.tar.gz");
        assert_eq!(v[0], "https://mirrors.kernel.org/gnu/screen/screen-5.0.0.tar.gz");
        assert!(v.contains(&"https://ftpmirror.gnu.org/screen/screen-5.0.0.tar.gz".to_string()));
        assert_eq!(candidate_urls("https://example.com/x.tgz").len(), 1);
    }

    #[test]
    fn cache_dir_is_stable_and_url_scoped() {
        let base = Path::new("/r");
        let a = remote_cache_dir(base, "https://m.example.com/stable");
        let b = remote_cache_dir(base, "https://m.example.com/stable");
        let c = remote_cache_dir(base, "https://m.example.com/testing");
        assert_eq!(a, b, "same URL must map to the same cache dir");
        assert_ne!(a, c, "different URLs must not share a cache dir");
        assert!(a.starts_with("/r/var/cache/dpm/remote"));
    }
}
