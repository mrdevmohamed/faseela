#!/usr/bin/env python3
"""Fast CLI/dry-run tests for the real installed-disk QEMU acceptance harness."""
from __future__ import annotations

import importlib.util
import io
import socket
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "qemu-installed-boot-test.py"


def check_serial_evidence() -> None:
    spec = importlib.util.spec_from_file_location("installed_boot", SCRIPT)
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    connection, guest = socket.socketpair()
    vm = harness.SerialVM([], Path("unused.sock"), Path("unused.log"))
    vm.connection = connection
    vm.process = type("Running", (), {"poll": lambda self: None})()
    vm.log_file = io.BytesIO()
    try:
        guest.sendall(b"doas echo FASEELA_ROOT_OK\r\n")
        try:
            vm.expect_line(b"FASEELA_ROOT_OK", 0.02, "root evidence")
        except harness.BootTestError:
            pass
        else:
            raise AssertionError("an echoed command was accepted as execution evidence")
        guest.sendall(b"\x1b[?2004l\x1b]3008;end=test\x1b\\FASEELA_ROOT_")
        guest.sendall(b"OK\r\n")
        vm.expect_line(b"FASEELA_ROOT_OK", 1, "root evidence")
        try:
            vm.expect_line(b"FASEELA_ROOT_OK", 0.02, "fresh root evidence")
        except harness.BootTestError:
            pass
        else:
            raise AssertionError("an old marker was reused")
        guest.sendall(b"\x1b]3008;end=test\x1b\\FASEELA_INSTALL_TEST_STATUS=1\r\n")
        result = vm.expect_pattern(
            rb"(?m)(?:^|\r|\x1b\\)FASEELA_INSTALL_TEST_STATUS=([0-9]+)\r?\n", 1, "installer result"
        )
        assert result.group(1) == b"1"
        guest.sendall(b"\x1b]3008;end=test\x1b\\FASEELA_BOOT_ACCEPTANCE system-profile=missing\r\n")
        profile = vm.expect_pattern(
            rb"(?m)(?:^|\r|\x1b\\)FASEELA_BOOT_ACCEPTANCE system-profile=([A-Za-z0-9_.-]+)\r?\n",
            1,
            "system-profile result",
        )
        assert profile.group(1) == b"missing"
    finally:
        guest.close()
        connection.close()

    # A guest reset closes the serial socket. The failure must include the
    # process status and QEMU's debug trace rather than hiding them behind EOF.
    with tempfile.TemporaryDirectory(prefix="faseela-qemu-eof-") as tmp:
        root = Path(tmp)
        host, peer = socket.socketpair()
        vm = harness.SerialVM([], root / "disk-serial.sock", root / "disk-serial.log")
        vm.connection = host
        vm.process = type("Exited", (), {"poll": lambda self: 42})()
        vm.log_file = io.BytesIO()
        vm.debug_log_path.write_text("CPU reset: triple fault", encoding="utf-8")
        peer.close()
        try:
            vm.expect(b"PID1_READY", 1, "installed PID 1")
        except harness.BootTestError as error:
            message = str(error)
            assert "exit status: 42" in message
            assert "CPU reset: triple fault" in message
            assert str(vm.debug_log_path) in message
        else:
            raise AssertionError("a closed serial stream was accepted as a boot")
        finally:
            host.close()


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def main() -> int:
    check_serial_evidence()
    # The real harness must use the Live user's doas rule for installation
    # and synchronization before the host stops the Live VM. The installed
    # disk is then booted in a fresh QEMU process.
    harness_source = SCRIPT.read_text(encoding="utf-8")
    assert "doas /usr/bin/env FASEELA_QEMU_BOOT_TEST=1" in harness_source
    assert "doas sync && printf" in harness_source
    assert "system-profile=([A-Za-z0-9_.-]+)" in harness_source
    installer_source = Path(REPO / "bootstrap/install.sh").read_text(encoding="utf-8")
    assert 'panic=60' in installer_source
    assert "terminal_output serial" in installer_source
    assert '"-d", "int,guest_errors,cpu_reset"' in harness_source
    assert '"-no-reboot"' not in harness_source
    assert 'screendump {screenshot}' in harness_source
    assert 'disk-serial-monitor.sock' in harness_source or 'serial_socket.stem + \'-monitor.sock\'' in harness_source
    assert 'default=120' in harness_source
    run_one = harness_source[harness_source.index("def run_one"):harness_source.index("def parse_args")]
    assert "wait_for_exit" not in run_one

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
            "doas /usr/bin/env FASEELA_QEMU_BOOT_TEST=1",
            "faseela-install /dev/sda --yes",
            "FW_FORCE=bios",
            "[uefi] install command:",
            "FW_FORCE=uefi",
            "ide-hd,drive=installed-disk,bootindex=2",
            "ide-hd,drive=installed-disk,bootindex=1",
            "ide-cd,drive=install-iso,bootindex=1",
            "if=none,id=installed-disk",
            "if=none,id=install-iso",
            "if=pflash,format=raw,readonly=on",
            "file=/usr/share/OVMF/OVMF_VARS.fd",
            "live-serial.sock",
            "disk-serial.sock",
            "-d int,guest_errors,cpu_reset",
            "live-serial-debug.log",
            "disk-serial-debug.log",
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
