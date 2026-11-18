#!/usr/bin/env python3
"""Fast CLI/dry-run tests for the real installed-disk QEMU acceptance harness."""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "qemu-installed-boot-test.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def main() -> int:
    help_result = run("--help")
    assert help_result.returncode == 0, help_result.stderr
    assert "installed disk" in help_result.stdout.lower()
    assert "--firmware" in help_result.stdout

    with tempfile.TemporaryDirectory(prefix="faseela-installed-boot-test-") as tmp:
        root = Path(tmp)
        iso = root / "faseela.iso"
        iso.write_bytes(b"test ISO placeholder")
        output = root / "artifacts"
        dry_run = run(
            str(iso),
            "--firmware", "both",
            "--out-dir", str(output),
            "--disk-size", "16G",
            "--dry-run",
        )
        assert dry_run.returncode == 0, dry_run.stderr
        for expected in (
            "[bios] install command:",
            "FW_FORCE=bios",
            "[uefi] install command:",
            "FW_FORCE=uefi",
            "-boot order=dc",
            "-boot order=c",
            "if=pflash,format=raw,readonly=on",
            "live-serial.sock",
            "disk-serial.sock",
        ):
            assert expected in dry_run.stdout, (expected, dry_run.stdout)

        bad_size = run(str(iso), "--disk-size", "16T", "--dry-run")
        assert bad_size.returncode != 0
        assert "--disk-size" in bad_size.stderr

        missing_iso = run(str(root / "missing.iso"))
        assert missing_iso.returncode != 0
        assert "ISO does not exist" in missing_iso.stderr

    print("PASS installed-disk QEMU harness CLI and BIOS/UEFI dry-run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
