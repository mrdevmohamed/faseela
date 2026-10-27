//! Interactive confirmation for destructive operations (`remove`, `upgrade`).
//!
//! Rules:
//! * `--yes` skips the question entirely (scripts, CI);
//! * non-interactive stdin without `--yes` **refuses** to run — silently
//!   defaulting to "no" would break automation, defaulting to "yes" would
//!   be dangerous (this is how apt's `-y` contract works);
//! * the prompt goes to **stderr** so stdout stays pipe-clean;
//! * declining aborts with a non-zero exit and a clear message.

use anyhow::{bail, Result};
use std::io::{IsTerminal, Write};

/// Ask until the user answers. `yes=true` short-circuits.
pub fn confirm(prompt: &str, yes: bool) -> Result<()> {
    if yes {
        return Ok(());
    }
    if !std::io::stdin().is_terminal() {
        bail!(
            "refusing to proceed non-interactively without --yes\n\
             (re-run with --yes, or answer the prompt in a terminal)"
        );
    }
    let mut err = std::io::stderr();
    write!(err, "{prompt} [y/N] ")?;
    err.flush()?;
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    match line.trim().to_ascii_lowercase().as_str() {
        "y" | "yes" => Ok(()),
        _ => bail!("aborted by user — nothing was changed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yes_flag_short_circuits() {
        // even in a non-interactive test harness, --yes must not error
        confirm("proceed?", true).unwrap();
    }

    #[test]
    fn non_interactive_without_yes_refuses() {
        // cargo test stdin is not a tty, so this is the refusal path
        let err = confirm("proceed?", false).unwrap_err();
        assert!(err.to_string().contains("--yes"));
    }
}
