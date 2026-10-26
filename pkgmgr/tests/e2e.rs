//! End-to-end test: recipe -> build -> install -> query -> remove
//! Uses a meta recipe (no downloads) against a temp root.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn dpm_bin() -> PathBuf {
    // cargo builds the binary for integration tests and tells us where it is
    PathBuf::from(env!("CARGO_BIN_EXE_dpm"))
}

#[test]
fn build_install_query_remove_roundtrip() {
    let scratch = std::env::temp_dir().join(format!("dpm-e2e-{}", std::process::id()));
    let _ = fs::remove_dir_all(&scratch);

    let recipes = scratch.join("recipes/hello");
    fs::create_dir_all(&recipes).unwrap();
    fs::write(
        recipes.join("recipe.toml"),
        r#"
[package]
name = "hello"
version = "1.0"
rel = 1
arch = ["x86_64"]
summary = "hello meta package"

[build]
install = """
mkdir -p %{pkgdir}/usr/bin
printf '#!/bin/sh\necho hello-dpm\n' > %{pkgdir}/usr/bin/hello
chmod +x %{pkgdir}/usr/bin/hello
"""
"#,
    )
    .unwrap();

    let root = scratch.join("rootfs");
    fs::create_dir_all(&root).unwrap();

    // build
    let out = Command::new(dpm_bin())
        .args([
            "--recipes", recipes.parent().unwrap().to_str().unwrap(),
            "--builddir", scratch.join("build").to_str().unwrap(),
            "build", "hello",
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "build failed:\n{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );

    let archive = scratch.join("build/out/hello-1.0-1.dpm.tar.zst");
    assert!(archive.exists(), "archive missing: {}", archive.display());

    // install
    let out = Command::new(dpm_bin())
        .args([
            "--root", root.to_str().unwrap(),
            "install", archive.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "install failed:\n{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(root.join("usr/bin/hello").exists());

    // query
    let out = Command::new(dpm_bin())
        .args(["--root", root.to_str().unwrap(), "query"])
        .output()
        .unwrap();
    let q = String::from_utf8_lossy(&out.stdout);
    assert!(q.contains("hello"), "query output missing hello: {q}");

    // owner
    let out = Command::new(dpm_bin())
        .args([
            "--root", root.to_str().unwrap(),
            "owner", "/usr/bin/hello",
        ])
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("hello"));

    // remove
    let out = Command::new(dpm_bin())
        .args(["--root", root.to_str().unwrap(), "remove", "hello"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "remove failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(!root.join("usr/bin/hello").exists());

    let _ = fs::remove_dir_all(&scratch);
}

#[test]
fn deps_all_skips_installed_unless_include_installed() {
    // regression: `deps-all` feeds the installed set into the resolver, which
    // treats "installed" as "done" — with everything installed the order came
    // back empty (stage3 STAGE3_WORLD=1 silently rebuilt nothing). The
    // --include-installed flag ignores the db and lists every recipe.
    let scratch = std::env::temp_dir().join(format!("dpm-e2e-depsall-{}", std::process::id()));
    let _ = fs::remove_dir_all(&scratch);

    let recipes = scratch.join("recipes");
    for (name, deps) in [("hello", ""), ("zzz", "")] {
        let dir = recipes.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("recipe.toml"),
            format!(
                "[package]\nname = \"{name}\"\nversion = \"1.0\"\n\n[depends]\nbuild = [{deps}]\n\n[build]\ninstall = \"\"\"\nmkdir -p %{{pkgdir}}/usr/bin\nprintf 'x' > %{{pkgdir}}/usr/bin/{name}\n\"\"\"\n"
            ),
        )
        .unwrap();
    }

    let root = scratch.join("rootfs");
    fs::create_dir_all(&root).unwrap();

    // build + install "hello" so the db records it
    let out = Command::new(dpm_bin())
        .args([
            "--recipes", recipes.to_str().unwrap(),
            "--builddir", scratch.join("build").to_str().unwrap(),
            "build", "hello",
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "build failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let archive = scratch.join("build/out/hello-1.0-1.dpm.tar.zst");
    let out = Command::new(dpm_bin())
        .args(["--root", root.to_str().unwrap(), "install", archive.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(out.status.success());

    let deps_all = |extra: &str| {
        let out = Command::new(dpm_bin())
            .args(["--root", root.to_str().unwrap(), "--recipes", recipes.to_str().unwrap()])
            .args(["deps-all"])
            .args(if extra.is_empty() { vec![] } else { vec![extra] })
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };

    // default: the installed "hello" is skipped
    assert_eq!(deps_all(""), "zzz", "installed packages must be skipped by default");
    // --include-installed: every recipe is listed
    assert_eq!(deps_all("--include-installed"), "hello\nzzz");
    let _ = fs::remove_dir_all(&scratch);
}
