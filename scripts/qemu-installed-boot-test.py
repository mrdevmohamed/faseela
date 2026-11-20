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
        self.debug_log_path = socket_path.with_name(socket_path.stem + "-debug.log")
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
            return_code = self.process.poll()
            if return_code is not None:
                raise BootTestError(
                    f"QEMU exited early with status {return_code};\n{self.diagnostics()}"
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

    def diagnostics(self) -> str:
        status = self.process.poll() if self.process is not None else "not started"

        def tail(path: Path, limit: int = 5000) -> str:
            try:
                return path.read_bytes()[-limit:].decode("utf-8", errors="replace")
            except OSError:
                return "(not available)"

        return (
            f"QEMU process exit status: {status}\n"
            f"Serial log: {self.log_path}\n"
            f"QEMU stderr log: {self.qemu_log_path}\n"
            f"QEMU debug log: {self.debug_log_path}\n"
            f"Last serial output:\n{tail(self.log_path)}\n"
            f"Last QEMU stderr:\n{tail(self.qemu_log_path)}\n"
            f"Last QEMU debug output:\n{tail(self.debug_log_path)}"
        )

    def send(self, value: str) -> None:
        if self.connection is None:
            raise BootTestError("QEMU serial connection is not open")
        self.connection.sendall(value.encode("utf-8"))

    def expect(self, needle: bytes, timeout: int, description: str) -> re.Match[bytes]:
        return self.expect_pattern(re.escape(needle), timeout, description)

    def expect_line(self, needle: bytes, timeout: int, description: str) -> re.Match[bytes]:
        # Require a complete output line: a marker inside a terminal's echoed
        # command is never evidence that the command actually ran. A serial
        # terminal may emit an extra carriage return before command output, so
        # accept CR as a line boundary. Interactive shells can also write OSC
        # integration metadata immediately before command output (terminated
        # by ESC-backslash) without emitting a CR; accept that boundary while
        # still requiring the marker to occupy the complete line.
        return self.expect_pattern(
            rb"(?m)(?:^|\r|\x1b\\)" + re.escape(needle) + rb"\r?\n",
            timeout,
            description,
        )

    def expect_pattern(self, pattern: bytes, timeout: int, description: str) -> re.Match[bytes]:
        if self.connection is None or self.process is None or self.log_file is None:
            raise BootTestError("QEMU serial connection is not open")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            buffered = bytes(self.buffer)
            match = re.search(pattern, buffered)
            if match is not None:
                del self.buffer[:match.end()]
                return match
            panic = re.search(rb"(?m)Kernel panic - not syncing:.*", buffered)
            if panic is not None:
                raise BootTestError(
                    f"guest kernel panicked before {description}\n{self.diagnostics()}"
                )
            return_code = self.process.poll()
            if return_code is not None:
                raise BootTestError(
                    f"QEMU exited ({return_code}) before {description}\n"
                    f"{self.diagnostics()}"
                )
            readable, _, _ = select.select(
                [self.connection], [], [], min(1.0, max(0, deadline - time.monotonic()))
            )
            if not readable:
                continue
            try:
                data = self.connection.recv(65536)
            except BlockingIOError:
                continue
            if not data:
                # The serial chardev can close just before QEMU exits after a
                # guest reset. Give the process a short grace period so the
                # report captures its real exit status instead of racing poll().
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
                raise BootTestError(
                    f"QEMU serial connection closed before {description}\n"
                    f"{self.diagnostics()}"
                )
            self.log_file.write(data)
            self.log_file.flush()
            self.buffer.extend(data)
            if len(self.buffer) > 2 * 1024 * 1024:
                del self.buffer[:-1024 * 1024]
        raise BootTestError(
            f"timed out waiting for {description} after {timeout}s\n"
            f"{self.diagnostics()}"
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
    debug_flags: str = "int,guest_errors,cpu_reset",
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
        "-d", debug_flags,
        "-D", str(serial_socket.with_name(serial_socket.stem + "-debug.log")),
    ]
    if firmware == "uefi":
        if not ovmf_code or ovmf_vars is None:
            raise BootTestError("UEFI command needs OVMF_CODE and a writable OVMF_VARS copy")
        command.extend([
            "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,file={ovmf_vars}",
        ])
    # Give every bootable device an explicit firmware boot index. SeaBIOS
    # does not necessarily initialize virtio-blk devices that are absent from
    # its boot order; a disk can therefore appear successfully installed yet
    # immediately reset when tested without the ISO. Keep the installer ISO
    # first and the target disk second, then boot the disk first in the fresh VM.
    command.extend([
        "-drive", f"file={disk},if=none,id=installed-disk,format=qcow2",
        "-device", "virtio-blk-pci,drive=installed-disk,bootindex=2" if iso is not None
        else "virtio-blk-pci,drive=installed-disk,bootindex=1",
    ])
    if iso is not None:
        command.extend([
            "-drive", f"file={iso},media=cdrom,if=none,id=install-iso",
            "-device", "ide-cd,drive=install-iso,bootindex=1",
        ])
    return command


ANSI_RE = re.compile(r"\x1b(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])")
# Lines of the installer transcript that say what happened to the bootloader.
INSTALLER_GREP = re.compile(
    r"(?i)grub|installing for|installation finished|firmware mode|partitioning|installing kernel|"
    r"root UUID|test: |warning|error|fail|faseela-install|done "
)
EARLY_DEATH_MARKERS = ("serial connection closed", "QEMU exited")


def installer_transcript(log_path: Path, limit: int = 60) -> str:
    """The installer's own lines (grub-install output, firmware mode, warnings) from the
    Live VM's serial log, so they appear in the job log and not only in an artifact."""
    try:
        text = log_path.read_bytes().decode("utf-8", errors="replace")
    except OSError:
        return "(live serial log not available)"
    lines = [ANSI_RE.sub("", line).rstrip() for line in text.replace("\r", "\n").split("\n")]
    wanted = [line for line in lines if line and INSTALLER_GREP.search(line)
              and "FASEELA_INSTALL_TEST_STATUS" not in line]
    return "\n".join(wanted[-limit:]) or "(no installer lines found)"


def triple_fault_summary(debug_log: Path) -> str:
    """Pull the last 'Triple fault' (or guest-error) register dump out of a QEMU -d log.

    Only the TCG accelerator logs this: under KVM a guest triple fault just ends the VM,
    which is why the KVM run shows nothing but the two power-on CPU resets."""
    try:
        text = debug_log.read_bytes().decode("utf-8", errors="replace")
    except OSError:
        return "(QEMU debug log not available)"
    index = text.rfind("Triple fault")
    if index < 0:
        errors = [line for line in text.splitlines() if "guest_error" in line.lower() or "Invalid" in line]
        return ("no 'Triple fault' in the TCG debug log"
                + (":\n" + "\n".join(errors[-10:]) if errors else ""))
    keep = ("EAX=", "EIP=", "CS =", "SS =", "DS =", "CR0=", "EFER=", "Code=")
    out = ["Triple fault; register state at the fault:"]
    for line in text[index:].splitlines()[1:40]:
        if line.startswith("CPU Reset"):
            break
        if line.startswith(keep):
            out.append("  " + line)
    return "\n".join(out)


def boot_installed_disk(
    args: argparse.Namespace,
    firmware: str,
    disk: Path,
    out_dir: Path,
    qemu: str,
    accel: list[str],
    ovmf_code: str | None,
    vars_copy: Path | None,
    name: str = "disk",
    debug_flags: str = "int,guest_errors,cpu_reset",
    timeout: int | None = None,
) -> None:
    """Boot the installed disk in a fresh QEMU and require PID 1 = systemd."""
    timeout = timeout or args.boot_timeout
    disk_socket = out_dir / f"{name}-serial.sock"
    disk_vm = SerialVM(
        qemu_command(
            qemu, firmware, disk, disk_socket, accel,
            args.memory_mib, args.cpus, None, ovmf_code, vars_copy, debug_flags,
        ),
        disk_socket,
        out_dir / f"{name}-serial.log",
    )
    try:
        print(f"[{firmware}] booting the installed disk through {firmware.upper()} "
              f"({'KVM' if 'kvm' in accel else 'TCG'})", flush=True)
        disk_vm.start()
        match = disk_vm.expect_pattern(
            rb"(?m)(?:^|\r|\x1b\\)FASEELA_BOOT_ACCEPTANCE pid1=([A-Za-z0-9_.-]+)\r?\n",
            timeout, "the installed-disk PID 1 probe",
        )
        profile = disk_vm.expect_pattern(
            rb"(?m)(?:^|\r|\x1b\\)FASEELA_BOOT_ACCEPTANCE system-profile=([A-Za-z0-9_.-]+)\r?\n",
            timeout,
            "the installed Faseela system profile",
        )
        profile_name = profile.group(1).decode("ascii")
        if profile_name != "systemd":
            raise BootTestError(
                f"[{firmware}] installed system profile={profile_name!r}, expected 'systemd'; "
                f"see {disk_vm.log_path}"
            )
        pid1 = match.group(1).decode("ascii")
        if pid1 != "systemd":
            raise BootTestError(
                f"[{firmware}] installed disk booted with PID 1={pid1!r}, expected 'systemd'; "
                f"see {disk_vm.log_path}"
            )
        print(
            f"[{firmware}] PASS: installed disk reached PID 1=systemd and system profile=systemd "
            f"(serial log: {disk_vm.log_path})",
            flush=True,
        )
    finally:
        disk_vm.close()


def diagnose_early_death(
    args: argparse.Namespace,
    firmware: str,
    disk: Path,
    out_dir: Path,
    qemu: str,
    ovmf_code: str | None,
    vars_copy: Path | None,
) -> None:
    """The KVM boot ended in a second or two with no serial output at all (a guest triple
    fault or reset before GRUB's menu). KVM hides where. Boot the same disk once more under
    TCG, which logs the fault, and print the verdict where the job log shows it."""
    print(f"[{firmware}] the installed disk died almost immediately under KVM; "
          "re-booting it under TCG to learn why", flush=True)
    debug_log = out_dir / "disk-tcg-serial-debug.log"
    try:
        boot_installed_disk(
            args, firmware, disk, out_dir, qemu, ["-accel", "tcg", "-cpu", "max"],
            ovmf_code, vars_copy, name="disk-tcg",
            debug_flags="cpu_reset,guest_errors", timeout=min(args.boot_timeout, 300),
        )
    except BootTestError as error:
        print(f"[{firmware}] TCG boot also failed: {str(error).splitlines()[0]}", flush=True)
        print(f"[{firmware}] {triple_fault_summary(debug_log)}", flush=True)
        serial = out_dir / "disk-tcg-serial.log"
        try:
            tail = serial.read_bytes().decode("utf-8", errors="replace")[-1500:]
        except OSError:
            tail = ""
        print(f"[{firmware}] TCG serial output (tail):\n{ANSI_RE.sub('', tail) or '(empty)'}", flush=True)
    else:
        print(f"[{firmware}] the installed disk BOOTS under TCG but not under KVM: the guest "
              "fault depends on the CPU the runner gives it, not on the disk contents", flush=True)


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
        prompt = live_vm.expect_pattern(
            rb"(?im)(password:[ \t]*|[^\r\n]*[#$] )", 60,
            "the Live user's password or shell prompt",
        )
        if prompt.group(1).lower().startswith(b"password:"):
            live_vm.send("\n")
        # Split the output token so even an echoed, line-wrapped command cannot
        # contain the complete success marker.
        live_vm.send("doas sh -c 'test \"$(id -u)\" -eq 0' && printf '%s%s\\n' FASEELA_ ROOT_OK\n")
        live_vm.expect_line(b"FASEELA_ROOT_OK", 60, "doas root access on the Live ISO")

        install = (
            f"doas /usr/bin/env FASEELA_QEMU_BOOT_TEST=1 NAWA_INSTALL_TEST=1 FW_FORCE={firmware} "
            "/usr/sbin/faseela-install /dev/vda --yes "
            "; result=$?; printf '%s%s=%s\\n' FASEELA_ INSTALL_TEST_STATUS \"$result\"\n"
        )
        print(f"[{firmware}] installing onto the disposable /dev/vda disk", flush=True)
        live_vm.send(install)
        result = live_vm.expect_pattern(
            rb"(?m)(?:^|\r|\x1b\\)FASEELA_INSTALL_TEST_STATUS=([0-9]+)\r?\n",
            args.install_timeout,
            "the disk installer to finish",
        )
        if result.group(1) != b"0":
            raise BootTestError(
                f"[{firmware}] installer exited with status {result.group(1).decode('ascii')}; "
                f"see {live_vm.log_path}"
            )
        # Flush the disposable disk, then power off the Live VM from the host.
        # Guest reboot is not needed for this test: a fresh QEMU process below
        # independently boots the installed disk with the same firmware.
        live_vm.send("doas sync && printf '%s\\n' FASEELA_INSTALL_TEST_SYNCED\n")
        live_vm.expect_line(
            b"FASEELA_INSTALL_TEST_SYNCED", 120,
            "the installed disk to be synchronized before the Live VM is stopped",
        )
    finally:
        live_vm.close()

    # What the installer said about the bootloader, in the job log (not only in an artifact).
    print(f"[{firmware}] installer transcript (grub/firmware lines):\n"
          f"{installer_transcript(out_dir / 'live-serial.log')}", flush=True)

    try:
        boot_installed_disk(args, firmware, disk, out_dir, qemu, accel, ovmf_code, vars_copy)
    except BootTestError as error:
        if "kvm" in accel and any(marker in str(error) for marker in EARLY_DEATH_MARKERS):
            diagnose_early_death(args, firmware, disk, out_dir, qemu, ovmf_code, vars_copy)
        raise


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

    failures: list[tuple[str, BootTestError]] = []
    for firmware in firmwares:
        try:
            run_one(args, firmware, ovmf_code, ovmf_vars)
        except BootTestError as error:
            # One firmware failing must not hide the other one's result.
            print(f"qemu-installed-boot-test: [{firmware}] FAILED: {error}", file=sys.stderr, flush=True)
            failures.append((firmware, error))
    passed = [fw for fw in firmwares if fw not in {name for name, _ in failures}]
    if failures:
        print("Installed-disk boot acceptance: "
              + ", ".join(f"{fw} PASS" for fw in passed)
              + (", " if passed else "")
              + ", ".join(f"{fw} FAIL" for fw, _ in failures), file=sys.stderr)
        return 1
    print("Installed-disk boot acceptance passed for: " + ", ".join(firmwares))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BootTestError, OSError, subprocess.CalledProcessError) as error:
        print(f"qemu-installed-boot-test: {error}", file=sys.stderr)
        raise SystemExit(1)
