#!/usr/bin/env python3
"""Boot an already-installed QEMU disk through multiple virtual controllers.

This diagnostic reuses the qcow2 disk produced by a failed installed-disk
acceptance job. It does not reinstall or mutate the image (QEMU is given a
read-only overlay so each boot is disposable).
"""
from __future__ import annotations

import argparse
import socket
import subprocess
import sys
import time
from pathlib import Path


def monitor_command(path: Path, command: str, timeout: float = 0.35) -> str:
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    try:
        connection.connect(str(path))
        try:
            connection.recv(4096)  # HMP greeting / prompt
        except OSError:
            pass
        connection.sendall((command + "\n").encode())
        chunks: list[bytes] = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                data = connection.recv(65536)
            except (TimeoutError, OSError):
                break
            if not data:
                break
            chunks.append(data)
        return b"".join(chunks).decode("utf-8", errors="replace")
    finally:
        connection.close()


def run_one(disk: Path, interface: str, outdir: Path, seconds: int) -> int:
    outdir.mkdir(parents=True, exist_ok=True)
    qemu = "qemu-system-x86_64"
    qemu_img = "qemu-img"
    overlay = outdir / "boot-overlay.qcow2"
    monitor = outdir / "monitor.sock"
    serial = outdir / "serial.log"
    stderr = outdir / "qemu.log"
    debug = outdir / "debug.log"

    for path in (overlay, monitor, serial, stderr, debug):
        path.unlink(missing_ok=True)

    subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-F", "qcow2",
         "-b", str(disk.resolve()), str(overlay)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if interface == "ide":
        disk_device = ["-device", "ide-hd,drive=installed-disk,bus=ide.0,bootindex=1"]
    else:
        disk_device = ["-device", "virtio-blk-pci,drive=installed-disk,bootindex=1"]

    command = [
        qemu,
        "-accel", "tcg", "-cpu", "max",
        "-m", "2048", "-smp", "2",
        "-display", "none", "-vga", "std", "-nic", "none",
        "-no-reboot",
        "-monitor", f"unix:{monitor},server,nowait",
        "-serial", f"file:{serial}",
        "-drive", f"file={overlay},if=none,id=installed-disk,format=qcow2",
        *disk_device,
        "-d", "int,guest_errors,cpu_reset", "-D", str(debug),
    ]

    print(f"[{interface}] booting read-only base disk via {interface}", flush=True)
    with stderr.open("wb") as qemu_log:
        process = subprocess.Popen(command, stdout=qemu_log, stderr=subprocess.STDOUT)

    start = time.monotonic()
    next_frame = 0
    frame = 0
    monitor_log = outdir / "monitor.log"
    while time.monotonic() - start < seconds and process.poll() is None:
        elapsed = time.monotonic() - start
        if elapsed >= next_frame:
            frame_path = outdir / f"screen-{frame:02d}.ppm"
            try:
                result = monitor_command(monitor, f"screendump {frame_path}")
                with monitor_log.open("a", encoding="utf-8") as handle:
                    handle.write(f"\n--- screendump t={elapsed:.1f}s ---\n{result}\n")
            except OSError as error:
                with monitor_log.open("a", encoding="utf-8") as handle:
                    handle.write(f"monitor unavailable at {elapsed:.1f}s: {error}\n")
            frame += 1
            next_frame += 2
        time.sleep(0.1)

    for item in ("info block", "info pci", "info roms", "info bootorder"):
        try:
            result = monitor_command(monitor, item)
        except OSError as error:
            result = f"monitor unavailable: {error}"
        with monitor_log.open("a", encoding="utf-8") as handle:
            handle.write(f"\n--- {item} ---\n{result}\n")

    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    output = serial.read_text(encoding="utf-8", errors="replace") if serial.exists() else ""
    pid_ok = "FASEELA_BOOT_ACCEPTANCE pid1=systemd" in output
    profile_ok = "FASEELA_BOOT_ACCEPTANCE system-profile=systemd" in output
    print(
        f"[{interface}] qemu_exit={process.returncode} "
        f"pid1_systemd={pid_ok} profile_systemd={profile_ok}",
        flush=True,
    )
    print(f"[{interface}] serial log: {serial}", flush=True)
    print(f"[{interface}] monitor log: {monitor_log}", flush=True)
    print(f"[{interface}] screenshots: {outdir}/screen-*.ppm", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("disk", type=Path)
    parser.add_argument("--interface", choices=("virtio", "ide"), required=True)
    parser.add_argument("--outdir", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=24)
    args = parser.parse_args()

    if not args.disk.is_file():
        parser.error(f"installed disk not found: {args.disk}")
    if args.seconds < 10:
        parser.error("--seconds must be at least 10")

    for tool in ("qemu-img", "qemu-system-x86_64"):
        if subprocess.run(["which", tool], stdout=subprocess.DEVNULL).returncode:
            raise SystemExit(f"required QEMU tool not found: {tool}")
    return run_one(args.disk, args.interface, args.outdir, args.seconds)


if __name__ == "__main__":
    raise SystemExit(main())
