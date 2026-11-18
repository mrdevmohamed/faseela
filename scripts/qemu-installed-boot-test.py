#!/usr/bin/env python3
"""Install Faseela onto a disposable QEMU disk and verify the real PID 1.

This is deliberately separate from qemu-boot-test.sh: booting the Live ISO and
seeing a login prompt does not prove that the installed disk, GRUB, and SAQ
initramfs select systemd.
"""
from __future__ import annotations

import argparse
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path


OVMF_CANDIDATES = (
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/usr/share/qemu/OVMF_CODE.fd",
)
OVMF_VARS_CANDIDATES = (
    "/usr/share/OVMF/OVMF_VARS_4M.fd",
    "/usr/share/OVMF/OVMF_VARS.fd",
    "/usr/share/edk2/ovmf/OVMF_VARS.fd",
    "/usr/share/qemu/OVMF_VARS.fd",
)


class BootTestError(RuntimeError):
    pass


class SerialVM:
    def __init__(self, command: list[str], socket_path: Path, log_path: Path):
        self.command = command
        self.socket_path = socket_path
        self.log_path = log_path
        self.qemu_log_path = log_path.with_name(log_path.stem + "-qemu.log")
        self.process: subprocess.Popen[bytes] | None = None
        self.connection: socket.socket | None = None
        self.log_file = None
        self.qemu_log_file = None
        self.buffer = bytearray()

    def start(self, connect_timeout: int = 30) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        self.socket_path.unlink(missing_ok=True)
        self.log_file = self.log_path.open("wb")
        self.qemu_log_file = self.qemu_log_path.open("wb")
        self.process = subprocess.Popen(
            self.command,
            stdin=subprocess.DEVNULL,
            stdout=self.qemu_log_file,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + connect_timeout
        last_error: OSError | None = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise BootTestError(
                    f"QEMU exited early with status {self.process.returncode}; "
                    f"see {self.qemu_log_path}"
                )
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                connection.connect(str(self.socket_path))
                connection.setblocking(False)
                self.connection = connection
                return
            except OSError as error:
                last_error = error
                connection.close()
                time.sleep(0.2)
        raise BootTestError(
            f"could not connect to QEMU serial socket {self.socket_path}: {last_error}"
        )

    def send(self, value: str) -> None:
        if self.connection is None:
            raise BootTestError("QEMU serial connection is not open")
        self.connection.sendall(value.encode("utf-8"))

    def expect(self, needle: bytes, timeout: int, description: str) -> None:
        if self.connection is None or self.process is None or self.log_file is None:
            raise BootTestError("QEMU serial connection is not open")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in self.buffer:
                return
            if self.process.poll() is not None:
                raise BootTestError(
                    f"QEMU exited ({self.process.returncode}) before {description}; "
                    f"see {self.log_path}"
                )
            readable, _, _ = select.select([self.connection], [], [], 1.0)
            if not readable:
                continue
            try:
                data = self.connection.recv(65536)
            except BlockingIOError:
                continue
            if not data:
                raise BootTestError(
                    f"QEMU serial connection closed before {description}; "
                    f"see {self.log_path}"
                )
            self.log_file.write(data)
            self.log_file.flush()
            self.buffer.extend(data)
            if len(self.buffer) > 2 * 1024 * 1024:
                del self.buffer[:-1024 * 1024]
        tail = bytes(self.buffer[-5000:]).decode("utf-8", errors="replace")
        raise BootTestError(
            f"timed out waiting for {description} after {timeout}s; "
            f"see {self.log_path}\nLast serial output:\n{tail}"
        )

    def wait_for_exit(self, timeout: int) -> None:
        if self.process is None:
            return
        try:
            return_code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise BootTestError(
                f"the Live guest did not reset after the installer reboot command "
                f"within {timeout}s; see {self.log_path}"
            ) from error
        if return_code != 0:
            raise BootTestError(
                f"QEMU exited with status {return_code} during the Live-to-disk reboot; "
                f"see {self.qemu_log_path}"
            )
        if self.log_file is not None:
            self.log_file.flush()
        if self.qemu_log_file is not None:
            self.qemu_log_file.flush()

    def close(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.connection is not None:
            self.connection.close()
            self.connection = None
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None
        if self.qemu_log_file is not None:
            self.qemu_log_file.close()
            self.qemu_log_file = None
        self.socket_path.unlink(missing_ok=True)


def resolve_ovmf(explicit: str | None) -> str:
    if explicit:
        candidate = Path(explicit)
        if not candidate.is_file():
            raise BootTestError(f"OVMF_CODE does not exist: {candidate}")
        return str(candidate)
    for item in OVMF_CANDIDATES:
        if Path(item).is_file():
            return item
    raise BootTestError(
        "UEFI test needs OVMF firmware; install the ovmf package or set OVMF_CODE"
    )


def resolve_ovmf_vars(explicit: str | None) -> str:
    if explicit:
        candidate = Path(explicit)
        if not candidate.is_file():
            raise BootTestError(f"OVMF_VARS does not exist: {candidate}")
        return str(candidate)
    for item in OVMF_VARS_CANDIDATES:
        if Path(item).is_file():
            return item
    raise BootTestError(
        "UEFI test needs a writable OVMF variables template; install the ovmf package "
        "or set OVMF_VARS"
    )


def acceleration_args(mode: str) -> list[str]:
    if mode == "auto":
        mode = "kvm" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg"
    if mode == "kvm":
        if not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise BootTestError("KVM requested, but /dev/kvm is not readable/writable")
        return ["-accel", "kvm", "-cpu", "host"]
    return ["-accel", "tcg", "-cpu", "max"]


def qemu_command(
    qemu: str,
    firmware: str,
    disk: Path,
    serial_socket: Path,
    accel: list[str],
    memory_mib: int,
    cpus: int,
    iso: Path | None = None,
    ovmf_code: str | None = None,
    ovmf_vars: Path | None = None,
) -> list[str]:
    command = [
        qemu,
        *accel,
        "-m", str(memory_mib),
        "-smp", str(cpus),
        "-display", "none",
        "-vga", "std",
        "-nic", "none",
        "-no-reboot",
        "-monitor", "none",
        "-serial", f"unix:{serial_socket},server,nowait",
    ]
    if firmware == "uefi":
        if not ovmf_code or ovmf_vars is None:
            raise BootTestError("UEFI command needs OVMF_CODE and a writable OVMF_VARS copy")
        command.extend([
            "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,file={ovmf_vars}",
        ])
    command.extend([
        "-drive", f"file={disk},if=virtio,format=qcow2",
    ])
    if iso is not None:
        command.extend(["-cdrom", str(iso), "-boot", "order=dc"])
    else:
        command.extend(["-boot", "order=c"])
    return command


def run_one(
    args: argparse.Namespace,
    firmware: str,
    ovmf_code: str | None,
    ovmf_vars_template: str | None,
) -> None:
    out_dir = Path(args.out_dir).resolve() / firmware
    out_dir.mkdir(parents=True, exist_ok=True)
    disk = out_dir / "installed.qcow2"
    if disk.exists():
        raise BootTestError(
            f"refusing to overwrite existing test disk {disk}; remove it or choose another --out-dir"
        )

    qemu_img = shutil.which("qemu-img")
    qemu = shutil.which("qemu-system-x86_64")
    if not qemu_img or not qemu:
        raise BootTestError("qemu-img and qemu-system-x86_64 must be installed")

    accel = acceleration_args(args.accel)
    vars_copy: Path | None = None
    if firmware == "uefi":
        if not ovmf_vars_template:
            raise BootTestError("UEFI test needs an OVMF_VARS template")
        vars_copy = out_dir / "OVMF_VARS.fd"
        if vars_copy.exists():
            raise BootTestError(
                f"refusing to overwrite existing UEFI variables file {vars_copy}; "
                "remove it or choose another --out-dir"
            )
        shutil.copyfile(ovmf_vars_template, vars_copy)

    subprocess.run(
        [qemu_img, "create", "-f", "qcow2", str(disk), args.disk_size],
        check=True,
    )

    live_socket = out_dir / "live-serial.sock"
    live_vm = SerialVM(
        qemu_command(
            qemu, firmware, disk, live_socket, accel,
            args.memory_mib, args.cpus, Path(args.iso).resolve(), ovmf_code, vars_copy,
        ),
        live_socket,
        out_dir / "live-serial.log",
    )
    try:
        print(f"[{firmware}] booting the Live ISO", flush=True)
        live_vm.start()
        live_vm.expect(b"login:", args.live_timeout, "the Live ISO login prompt")
        # The Live image creates the passwordless live user and a narrowly
        # scoped nopass doas rule. Use that documented path rather than relying
        # on root login being enabled on every serial getty configuration.
        live_vm.send("live\n")
        time.sleep(0.5)
        live_vm.send("\n")
        time.sleep(0.5)
        live_vm.send("doas sh -c 'test \"$(id -u)\" -eq 0 && echo FASEELA_ROOT_OK'\n")
        live_vm.expect(b"FASEELA_ROOT_OK", 60, "doas root access on the Live ISO")

        install = (
            f"doas /usr/bin/env FASEELA_QEMU_BOOT_TEST=1 NAWA_INSTALL_TEST=1 FW_FORCE={firmware} "
            "/usr/sbin/faseela-install /dev/vda --yes "
            "&& echo FASEELA_INSTALL_TEST_DONE\n"
        )
        print(f"[{firmware}] installing onto the disposable /dev/vda disk", flush=True)
        live_vm.send(install)
        live_vm.expect(
            b"FASEELA_INSTALL_TEST_DONE",
            args.install_timeout,
            "the disk installer to finish",
        )
        live_vm.send("sync; reboot -f\n")
        live_vm.wait_for_exit(120)
    finally:
        live_vm.close()

    disk_socket = out_dir / "disk-serial.sock"
    disk_vm = SerialVM(
        qemu_command(
            qemu, firmware, disk, disk_socket, accel,
            args.memory_mib, args.cpus, None, ovmf_code, vars_copy,
        ),
        disk_socket,
        out_dir / "disk-serial.log",
    )
    try:
        print(f"[{firmware}] booting the installed disk through {firmware.upper()}", flush=True)
        disk_vm.start()
        marker = b"FASEELA_BOOT_ACCEPTANCE pid1="
        disk_vm.expect(marker, args.boot_timeout, "the installed-disk PID 1 probe")
        match = re.search(rb"FASEELA_BOOT_ACCEPTANCE pid1=([A-Za-z0-9_.-]+)", disk_vm.buffer)
        if match is None:
            raise BootTestError(
                f"[{firmware}] PID 1 probe appeared but its value could not be parsed; "
                f"see {disk_vm.log_path}"
            )
        pid1 = match.group(1).decode("ascii")
        if pid1 != "systemd":
            raise BootTestError(
                f"[{firmware}] installed disk booted with PID 1={pid1!r}, expected 'systemd'; "
                f"see {disk_vm.log_path}"
            )
        print(
            f"[{firmware}] PASS: installed disk reached PID 1=systemd "
            f"(serial log: {disk_vm.log_path})",
            flush=True,
        )
    finally:
        disk_vm.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install Faseela in QEMU and assert /proc/1/comm=systemd on the installed disk."
    )
    parser.add_argument("iso", help="Faseela ISO to install from")
    parser.add_argument("--out-dir", default="qemu-installed-boot", help="directory for disks and serial logs")
    parser.add_argument("--firmware", choices=("bios", "uefi", "both"), default="both")
    parser.add_argument("--disk-size", default="16G", help="disposable qcow2 disk size (default: 16G)")
    parser.add_argument("--memory-mib", type=int, default=2048)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--accel", choices=("auto", "kvm", "tcg"), default="auto")
    parser.add_argument("--live-timeout", type=int, default=600)
    parser.add_argument("--install-timeout", type=int, default=2400)
    parser.add_argument("--boot-timeout", type=int, default=600)
    parser.add_argument("--ovmf-code", default=os.environ.get("OVMF_CODE"))
    parser.add_argument("--ovmf-vars", default=os.environ.get("OVMF_VARS"))
    parser.add_argument("--dry-run", action="store_true", help="print the QEMU commands without starting them")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    iso = Path(args.iso).resolve()
    if not iso.is_file() and not args.dry_run:
        raise BootTestError(f"ISO does not exist: {iso}")
    if not re.fullmatch(r"[1-9][0-9]*[GM]", args.disk_size):
        raise BootTestError("--disk-size must look like 16G or 512M")
    if min(args.memory_mib, args.cpus, args.live_timeout, args.install_timeout, args.boot_timeout) <= 0:
        raise BootTestError("memory, CPUs and timeout values must all be positive")

    firmwares = ("bios", "uefi") if args.firmware == "both" else (args.firmware,)
    ovmf_code = None
    ovmf_vars = None
    if "uefi" in firmwares:
        if args.dry_run:
            ovmf_code = args.ovmf_code or "/usr/share/OVMF/OVMF_CODE.fd"
            ovmf_vars = args.ovmf_vars or "/usr/share/OVMF/OVMF_VARS.fd"
        else:
            ovmf_code = resolve_ovmf(args.ovmf_code)
            ovmf_vars = resolve_ovmf_vars(args.ovmf_vars)

    if args.dry_run:
        accel = ["-accel", "tcg", "-cpu", "max"] if args.accel != "kvm" else ["-accel", "kvm", "-cpu", "host"]
        for firmware in firmwares:
            disk = Path(args.out_dir).resolve() / firmware / "installed.qcow2"
            serial = Path(args.out_dir).resolve() / firmware / "live-serial.sock"
            print(f"[{firmware}] install command: doas /usr/bin/env FASEELA_QEMU_BOOT_TEST=1 NAWA_INSTALL_TEST=1 FW_FORCE={firmware} /usr/sbin/faseela-install /dev/vda --yes")
            for stage, image in (("install", iso), ("disk", None)):
                sock = serial if stage == "install" else disk.parent / "disk-serial.sock"
                cmd = qemu_command(
                    "qemu-system-x86_64", firmware, disk, sock, accel,
                    args.memory_mib, args.cpus, image, ovmf_code,
                    Path(ovmf_vars) if ovmf_vars else None,
                )
                print(f"[{firmware}] {stage} QEMU: {' '.join(cmd)}")
        return 0

    for firmware in firmwares:
        run_one(args, firmware, ovmf_code, ovmf_vars)
    print("Installed-disk boot acceptance passed for: " + ", ".join(firmwares))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BootTestError, OSError, subprocess.CalledProcessError) as error:
        print(f"qemu-installed-boot-test: {error}", file=sys.stderr)
        raise SystemExit(1)
