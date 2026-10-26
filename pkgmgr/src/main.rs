//! DPM — Distro Package Manager
//! A source-based package manager for a from-scratch Linux distribution.

mod archive;
mod build;
mod buildenv;
mod closure;
mod db;
mod deps;
mod fetch;
mod install;
mod lint;
mod lock;
mod profile;
mod recipe;
mod repo;
mod sandbox;
mod service;
mod sign;
mod upgrade;
mod version;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(
    name = "dpm",
    version,
    about = "DPM — source-based package manager for a from-scratch Linux distribution"
)]
struct Cli {
    /// Target root filesystem (use a throwaway dir for testing)
    #[arg(long, default_value = "/")]
    root: PathBuf,

    /// Root of the recipes tree
    #[arg(long, default_value = "recipes")]
    recipes: PathBuf,

    /// Scratch/build directory
    #[arg(long, default_value = "build")]
    builddir: PathBuf,

    /// Directory with per-architecture build profiles (`<arch>.toml`)
    #[arg(long, default_value = "profiles")]
    profiles: PathBuf,

    /// Parallel build jobs (default: the profile's `jobs`, else the CPU count)
    #[arg(long)]
    jobs: Option<u32>,

    #[command(subcommand)]
    cmd: Cmd,
}

fn default_jobs() -> u32 {
    std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(4)
}

#[derive(Subcommand)]
enum Cmd {
    /// Build a package from its recipe (by name inside --recipes)
    Build {
        name: String,
        /// Run the recipe's `check` section (test suite) after compiling;
        /// a failing check aborts the build
        #[arg(long)]
        check: bool,
        /// Like --check, but a failing test suite only prints a warning
        #[arg(long)]
        check_nonfatal: bool,
        /// Isolation level for the build: none | env | sandbox | closure
        /// (default: the profile's [build] isolation, else none)
        #[arg(long)]
        isolation: Option<String>,
        /// Build twice in different directories and compare archive hashes
        /// (reproducibility check; implies at least env isolation)
        #[arg(long)]
        rebuild_check: bool,
        /// Permit a recipe's [sandbox] network = true (recorded as impure)
        #[arg(long)]
        allow_network: bool,
        /// Continue when the host kernel refuses an isolation feature
        /// (by default the build stops instead of silently weakening)
        #[arg(long)]
        allow_degraded: bool,
        /// Per-section wall-clock limit in seconds (sandbox levels)
        #[arg(long)]
        timeout: Option<u64>,
        /// Skip the build when an archive for this package already exists
        /// and its recorded build_id matches the current inputs
        /// (recipe bytes, source sha256, closure, profile flags)
        #[arg(long)]
        use_cache: bool,
    },

    /// Install a built .dpm.tar.zst archive into --root
    Install {
        file: PathBuf,
        /// Overwrite files owned by other packages
        #[arg(long)]
        force: bool,
        /// Accept packages without a signature (rejected when trust keys exist)
        #[arg(long)]
        allow_unsigned: bool,
        /// Verify the package signature against this public key instead of the trust store
        #[arg(long)]
        key: Option<PathBuf>,
    },

    /// Print the dependency resolution order for a package
    Deps { name: String },

    /// Print the global build order for ALL recipes in the tree
    /// (one bare package name per line — script-friendly). Packages already
    /// recorded in the local db are skipped (use --include-installed to list
    /// them too, e.g. for a full world rebuild).
    DepsAll {
        /// also list packages already recorded in the local db
        /// (the default skips them, which is what a resuming stage2 wants;
        /// a stage3 world rebuild needs every recipe)
        #[arg(long)]
        include_installed: bool,
    },

    /// Remove an installed package
    Remove {
        name: String,
        /// remove even if other packages depend on it
        #[arg(long)]
        force: bool,
    },

    /// List installed packages
    Query,

    /// List files owned by an installed package
    Files { name: String },

    /// Find which installed package owns a file
    Owner { file: String },

    /// Create a repository index from a directory of archives
    #[command(name = "repo-create")]
    RepoCreate {
        dir: PathBuf,
        #[arg(long, default_value = "index.toml")]
        out: PathBuf,
        /// Sign index.toml after writing it
        #[arg(long)]
        sign: bool,
        /// Signing key for --sign
        #[arg(long)]
        key: Option<PathBuf>,
    },

    /// Generate an ed25519 signing keypair (dpm.sec + dpm.pub)
    Keygen {
        /// Directory for the keypair (default: /etc/dpm/keys or ~/.config/dpm/keys)
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// Sign a package archive or index.toml (writes <file>.sig)
    Sign {
        file: PathBuf,
        /// Signing key (default: DPM_SIGN_KEY / /etc/dpm/keys/dpm.sec)
        #[arg(long)]
        key: Option<PathBuf>,
    },

    /// Verify a signature on a package archive or index
    Verify {
        file: PathBuf,
        /// Verify against this public key (default: trust store, then embedded key)
        #[arg(long)]
        key: Option<PathBuf>,
    },

    /// Add a public key to the trust store (<root>/etc/dpm/trusted-keys)
    Trust { keyfile: PathBuf },

    /// Upgrade installed packages from a repository (index.toml)
    Upgrade {
        /// Repository directory or http(s) URL containing index.toml
        #[arg(long)]
        repo: String,
        /// Show the upgrade plan without changing anything
        #[arg(long)]
        dry_run: bool,
        /// Overwrite files owned by other packages
        #[arg(long)]
        force: bool,
        /// Accept unsigned archives when trust keys exist
        #[arg(long)]
        allow_unsigned: bool,
    },

    /// Roll a package back to the version recorded in its undo log
    Rollback { name: String },

    /// Manage runit services (enable/disable/list/status)
    Service {
        #[command(subcommand)]
        action: ServiceCmd,
    },

    /// Run one sandbox spec (internal; used by `dpm build`)
    #[command(hide = true)]
    SandboxInit {
        /// path to the spec.toml written by the build engine
        spec: PathBuf,
    },

    /// Report which sandbox features this kernel allows (internal/tests)
    #[command(hide = true)]
    SandboxProbe {
        /// run a single probe: userns | mounts | ro-bind | proc | pivot | netns-lo
        op: Option<String>,
    },
}

#[derive(Subcommand)]
enum ServiceCmd {
    /// List services in /etc/sv and their enabled state
    List,
    /// Enable a service (link into the default runsvdir)
    Enable { name: String },
    /// Disable a service (remove the runsvdir link)
    Disable { name: String },
    /// Show service status (static state + live `sv status` when supervised)
    Status { name: Option<String> },
}

struct Ctx {
    root: PathBuf,
    recipes: PathBuf,
    builddir: PathBuf,
    profiles: PathBuf,
    jobs: Option<u32>,
}

fn main() {
    let Cli { root, recipes, builddir, profiles, jobs, cmd } = Cli::parse();
    let ctx = Ctx { root, recipes, builddir, profiles, jobs };
    if let Err(e) = run(&ctx, cmd) {
        eprintln!("dpm: error: {e:#}");
        std::process::exit(1);
    }
}

/// Which database lock a command needs: writers exclusive, readers shared.
/// Taken once here (the library functions never lock — `upgrade` calls
/// `install_archive`, and flock would deadlock against itself).
fn lock_mode(cmd: &Cmd) -> Option<lock::Mode> {
    use lock::Mode::{Exclusive, Shared};
    match cmd {
        Cmd::Install { .. } | Cmd::Remove { .. } | Cmd::Rollback { .. } => Some(Exclusive),
        Cmd::Upgrade { dry_run, .. } => Some(if *dry_run { Shared } else { Exclusive }),
        Cmd::Query | Cmd::Files { .. } | Cmd::Owner { .. } | Cmd::Deps { .. } | Cmd::DepsAll { .. } => {
            Some(Shared)
        }
        Cmd::SandboxInit { .. } | Cmd::SandboxProbe { .. } => None,
        _ => None,
    }
}

fn run(ctx: &Ctx, cmd: Cmd) -> Result<()> {
    // held until `run` returns
    let _db_lock = match lock_mode(&cmd) {
        Some(mode) => lock::acquire(&ctx.root, mode)?,
        None => None,
    };
    match cmd {
        Cmd::Build {
            name,
            check,
            check_nonfatal,
            isolation,
            rebuild_check,
            allow_network,
            allow_degraded,
            timeout,
            use_cache,
        } => {
            let mode = if check_nonfatal {
                build::CheckMode::Warn
            } else if check {
                build::CheckMode::Fatal
            } else {
                build::CheckMode::Off
            };
            cmd_build(
                ctx,
                &name,
                mode,
                isolation.as_deref(),
                rebuild_check,
                allow_network,
                allow_degraded,
                timeout,
                use_cache,
            )
        }
        Cmd::Install { file, force, allow_unsigned, key } => {
            cmd_install(ctx, &file, force, allow_unsigned, key)
        }
        Cmd::Deps { name } => cmd_deps(ctx, &name),
        Cmd::DepsAll { include_installed } => cmd_deps_all(ctx, include_installed),
        Cmd::Remove { name, force } => install::remove_with(&name, &ctx.root, force),
        Cmd::Query => cmd_query(ctx),
        Cmd::Files { name } => cmd_files(ctx, &name),
        Cmd::Owner { file } => cmd_owner(ctx, &file),
        Cmd::RepoCreate { dir, out, sign, key } => {
            // a relative --out lands inside the repo dir, not in the CWD
            let out = if out.is_absolute() { out } else { dir.join(out) };
            repo::create_index(&dir, &out)?;
            if sign {
                let kp = sign::resolve_signing_key(key.as_deref())?;
                let sp = sign::sign(&out, &kp)?;
                println!("dpm: signed index -> {}", sp.display());
            }
            Ok(())
        }
        Cmd::Keygen { out } => {
            let dir = out.unwrap_or_else(sign::default_key_dir);
            let (sec, pub_) = sign::keygen(&dir)?;
            println!("dpm: secret key  {}  (keep safe, mode 0600)", sec.display());
            println!("dpm: public key  {}  (share / `dpm trust` on targets)", pub_.display());
            Ok(())
        }
        Cmd::Sign { file, key } => {
            let kp = sign::resolve_signing_key(key.as_deref())?;
            let sp = sign::sign(&file, &kp)?;
            println!("dpm: signed {} -> {}", file.display(), sp.display());
            Ok(())
        }
        Cmd::Verify { file, key } => {
            sign::verify_standalone(&file, &ctx.root, key.as_deref())?;
            Ok(())
        }
        Cmd::Trust { keyfile } => {
            let dest = sign::trust(&keyfile, &ctx.root)?;
            println!("dpm: trusted key installed at {}", dest.display());
            Ok(())
        }
        Cmd::Upgrade { repo, dry_run, force, allow_unsigned } => {
            let repo_ref = fetch::RepoRef::parse(&repo)?;
            upgrade::upgrade(
                &ctx.root,
                &repo_ref,
                &ctx.recipes,
                &upgrade::UpgradeOpts { dry_run, force, allow_unsigned },
            )
        }
        Cmd::Rollback { name } => install::rollback(&name, &ctx.root),
        Cmd::Service { action } => match action {
            ServiceCmd::List => service::print_list(&ctx.root),
            ServiceCmd::Enable { name } => {
                service::enable(&ctx.root, &name)?;
                println!(
                    "dpm: enabled {name} — runsvdir picks it up within seconds \
                     (use `sv up {name}` to start it right now)"
                );
                Ok(())
            }
            ServiceCmd::Disable { name } => {
                service::disable(&ctx.root, &name)?;
                println!(
                    "dpm: disabled {name} — runsvdir stops it within seconds \
                     (use `sv down {name}` to stop it right now)"
                );
                Ok(())
            }
            ServiceCmd::Status { name } => service::print_status(&ctx.root, name.as_deref()),
        },
        Cmd::SandboxInit { spec } => {
            let code = sandbox::init(&spec)?;
            std::process::exit(code);
        }
        Cmd::SandboxProbe { op } => {
            // a single probe runs in this process; the full mode spawns one
            // process per op, because each probe creates namespaces and
            // nesting them in one process corrupts the results
            match op {
                Some(o) => {
                    let ok = match sandbox::probe(&o) {
                        Ok(true) => {
                            println!("PASS  {o}");
                            true
                        }
                        Ok(false) => {
                            println!("FAIL  {o}");
                            false
                        }
                        Err(e) => {
                            println!("ERROR {o}: {e:#}");
                            false
                        }
                    };
                    std::process::exit(if ok { 0 } else { 1 });
                }
                None => {
                    let exe = std::env::current_exe().context("locate the dpm binary")?;
                    let mut all_ok = true;
                    for o in sandbox::PROBES {
                        let out = std::process::Command::new(&exe)
                            .arg("sandbox-probe")
                            .arg(o)
                            .output()
                            .with_context(|| format!("run probe {o}"))?;
                        let text = String::from_utf8_lossy(&out.stdout);
                        let one_line = text
                            .lines()
                            .find(|l| l.starts_with("PASS") || l.starts_with("FAIL"))
                            .unwrap_or_default();
                        println!("{one_line}");
                        if !out.status.success() {
                            all_ok = false;
                        }
                    }
                    if all_ok {
                        println!("sandbox probe: OK — all features available");
                    } else {
                        println!("sandbox probe: some features are missing (restricted kernel/container?)");
                        println!(
                            "dpm build refuses to weaken isolation silently; pass \
                             --allow-degraded to continue"
                        );
                    }
                    std::process::exit(if all_ok { 0 } else { 1 });
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn cmd_build(
    ctx: &Ctx,
    name: &str,
    check: build::CheckMode,
    isolation: Option<&str>,
    rebuild_check: bool,
    allow_network: bool,
    allow_degraded: bool,
    timeout: Option<u64>,
    use_cache: bool,
) -> Result<()> {
    let rec = recipe::load_by_name(&ctx.recipes, name)?;
    let arch = rec.arch();
    let profile = profile::Profile::load(&ctx.profiles, &arch)?;
    let env = profile.as_ref().map(|p| p.env()).unwrap_or_default();
    // precedence: --jobs > profile `jobs` > number of CPUs
    let jobs = ctx
        .jobs
        .or_else(|| profile.as_ref().and_then(|p| p.jobs))
        .unwrap_or_else(default_jobs);
    if !env.is_empty() {
        let flags: Vec<String> = env.iter().map(|(k, v)| format!("{k}={v}")).collect();
        println!("dpm: profile {arch}: {}", flags.join(" "));
    }

    // isolation precedence: --isolation > profile [build] isolation > none
    let build_profile = std::fs::read_to_string(ctx.profiles.join(format!("{arch}.toml")))
        .ok()
        .and_then(|raw| profile::Profile::parse_build(&raw).ok())
        .unwrap_or_default();
    let isolation = match isolation {
        Some(s) => buildenv::Isolation::parse(s)?,
        None => match build_profile.isolation.as_deref() {
            Some(s) if !s.trim().is_empty() => buildenv::Isolation::parse(s)?,
            _ => buildenv::Isolation::None,
        },
    };
    let timeout_secs = timeout.or(build_profile.timeout).unwrap_or(0);

    let profile_flags = env
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(" ");

    let opts = build::BuildOpts {
        jobs,
        builddir: ctx.builddir.clone(),
        outdir: ctx.builddir.join("out"),
        env,
        check,
        isolation,
        timeout_secs,
        allow_network,
        allow_degraded,
        root: ctx.root.clone(),
        recipes_root: ctx.recipes.clone(),
        allow_unsigned: false,
        profile_flags,
        use_cache,
    };
    if rebuild_check {
        build::rebuild_check(&rec, &opts)?;
    } else {
        build::build(&rec, &opts)?;
    }
    Ok(())
}

fn cmd_install(
    ctx: &Ctx,
    file: &Path,
    force: bool,
    allow_unsigned: bool,
    key: Option<PathBuf>,
) -> Result<()> {
    if !file.exists() {
        bail!("archive not found: {}", file.display());
    }
    install::install_archive(file, &ctx.root, force, allow_unsigned, key.as_deref(), "explicit")?;
    Ok(())
}

fn cmd_deps(ctx: &Ctx, name: &str) -> Result<()> {
    let db = db::Db::new(&ctx.root);
    let installed: HashSet<String> =
        db.installed()?.into_iter().map(|e| e.name).collect();
    let order = deps::resolve_from_recipes(&ctx.recipes, &[name.to_string()], &installed)?;
    for (i, r) in order.iter().enumerate() {
        println!("{:>3}. {} (build deps: {})",
            i + 1,
            r.id(),
            if r.depends.build.is_empty() { "-".into() } else { r.depends.build.join(", ") }
        );
    }
    Ok(())
}

fn cmd_deps_all(ctx: &Ctx, include_installed: bool) -> Result<()> {
    let all = recipe::load_all(&ctx.recipes)?;
    if all.is_empty() {
        bail!("no recipes found under {}", ctx.recipes.display());
    }
    let db = db::Db::new(&ctx.root);
    // default: skip what the db already records (a resumed stage2 rebuilds
    // only what is missing). --include-installed ignores the db entirely so
    // a stage3 world rebuild actually rebuilds everything — the resolver
    // treats "installed" as "done", which would otherwise empty the order.
    let installed: HashSet<String> = if include_installed {
        HashSet::new()
    } else {
        db.installed()?.into_iter().map(|e| e.name).collect()
    };
    let targets: Vec<String> = all.keys().cloned().collect();
    let order = deps::resolve(&targets, &installed, &all)?;
    for r in order {
        println!("{}", r.package.name);
    }
    Ok(())
}

fn cmd_query(ctx: &Ctx) -> Result<()> {
    let db = db::Db::new(&ctx.root);
    let pkgs = db.installed()?;
    if pkgs.is_empty() {
        println!("dpm: no packages installed in {}", ctx.root.display());
        return Ok(());
    }
    for p in pkgs {
        println!("{:<24} {:<12} rel-{:<3} {}", p.name, p.version, p.rel, p.reason);
    }
    Ok(())
}

fn cmd_files(ctx: &Ctx, name: &str) -> Result<()> {
    let db = db::Db::new(&ctx.root);
    if db.entry(name)?.is_none() {
        bail!("`{name}` is not installed");
    }
    for f in db.files(name)? {
        println!("{f}");
    }
    Ok(())
}

fn cmd_owner(ctx: &Ctx, file: &str) -> Result<()> {
    let db = db::Db::new(&ctx.root);
    let owners = db.file_owners()?;
    match owners.get(file) {
        Some(owner) => println!("{file} is owned by {owner}"),
        None => bail!("no installed package owns {file}"),
    }
    Ok(())
}
