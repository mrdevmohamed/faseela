#!/usr/bin/env python3
"""Send detailed Faseela CI/build reports and available artifacts to Telegram.

The notifier is deliberately best-effort: Telegram delivery must never change
the result of a CI, build, or release workflow.
"""
from __future__ import annotations

import html
import json
import os
import re
import tarfile
import tempfile
from pathlib import Path
from typing import Mapping
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# Telegram's hosted Bot API currently limits sendDocument uploads to 50 MB.
# Keep a margin for multipart overhead and future API-side changes.
MAX_DOCUMENT_BYTES = 49 * 1024 * 1024
MAX_LOG_FILES = 200
MAX_LOG_FILE_BYTES = 2 * 1024 * 1024
MAX_LOG_ARCHIVE_INPUT_BYTES = 20 * 1024 * 1024
LOG_SUFFIXES = {".log", ".txt"}
SECRET_PATTERNS = (
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(rb"\b\d{8,}:[A-Za-z0-9_-]{25,}\b"),
    re.compile(rb"(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s]+"),
    re.compile(rb"(?i)((?:token|password|passwd|secret)\s*[:=]\s*)[^\s]+"),
)


def parse_job_results(raw: str) -> list[tuple[str, str]]:
    parsed: list[tuple[str, str]] = []
    for item in raw.split(","):
        name, separator, result = item.strip().partition("=")
        if separator and name and result:
            parsed.append((name, result.lower()))
    return parsed


def overall_status(results: list[tuple[str, str]]) -> str:
    values = {result for _, result in results}
    if values & {"failure", "timed_out", "action_required"}:
        return "failure"
    if "cancelled" in values:
        return "cancelled"
    if values & {"in_progress", "queued"}:
        return "running"
    return "success"


def _escape(value: str) -> str:
    return html.escape(value or "—", quote=True)


def build_message(environ: Mapping[str, str]) -> str:
    results = parse_job_results(environ.get("JOB_RESULTS", ""))
    phase = environ.get("TELEGRAM_PHASE", "").lower()
    status = "running" if phase == "started" else overall_status(results)
    labels = {
        "success": ("✅", "نجح البناء"),
        "failure": ("❌", "فشل البناء"),
        "cancelled": ("🚫", "تم إلغاء التشغيل"),
        "running": ("⏳", "بدأ البناء" if phase == "started" else "التشغيل ما زال جارياً"),
    }
    icon, title = labels[status]
    repository = environ.get("GITHUB_REPOSITORY", "")
    server = environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    run_id = environ.get("GITHUB_RUN_ID", "")
    run_url = f"{server}/{repository}/actions/runs/{run_id}" if repository and run_id else server
    branch = environ.get("BRANCH_NAME") or environ.get("GITHUB_REF_NAME", "")
    sha = environ.get("GITHUB_SHA", "")[:10]
    jobs = "\n".join(f"{name}: {result}" for name, result in results) or "لا توجد بيانات وظائف"
    lines = [
        f"<b>{icon} Faseela — {title}</b>",
        f"<b>Workflow:</b> <code>{_escape(environ.get('GITHUB_WORKFLOW', ''))}</code>",
        f"<b>Repository:</b> <code>{_escape(repository)}</code>",
        f"<b>Branch:</b> <code>{_escape(branch)}</code>",
        f"<b>Commit:</b> <code>{_escape(sha)}</code>",
        f"<b>Run:</b> <code>#{_escape(environ.get('GITHUB_RUN_NUMBER', run_id))}</code>",
        f"<b>Event:</b> <code>{_escape(environ.get('GITHUB_EVENT_NAME', ''))}</code>",
        f"<b>By:</b> <code>{_escape(environ.get('GITHUB_ACTOR', ''))}</code>",
        f"<b>Attempt:</b> <code>{_escape(environ.get('GITHUB_RUN_ATTEMPT', ''))}</code>",
    ]
    if environ.get("PR_NUMBER"):
        lines.append(f"<b>Pull request:</b> <code>#{_escape(environ['PR_NUMBER'])}</code>")
    lines.extend((f"<b>Jobs:</b>\n<code>{_escape(jobs)}</code>",
                  f'<a href="{_escape(run_url)}">فتح تفاصيل التشغيل وسجلات GitHub Actions</a>'))
    release_url = environ.get("TELEGRAM_RELEASE_URL", "").strip()
    if release_url:
        lines.append('<a href="' + _escape(release_url) + '">تنزيل ملفات البناء من GitHub Release</a>')
    else:
        lines.append('<a href="' + _escape(run_url) + '">ملفات البناء (Artifacts) على GitHub Actions</a>')
    return "\n".join(lines)


def _api_result(response) -> dict:
    result = json.loads(response.read().decode("utf-8"))
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RuntimeError("Telegram API returned an unsuccessful response")
    return result


def send_message(token: str, chat_id: str, message: str) -> None:
    payload = {
        "chat_id": chat_id,
        "text": message[:3900],
        "parse_mode": "HTML",
        "link_preview_options": {"is_disabled": True},
    }
    request = Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=15) as response:
        _api_result(response)


def send_document(token: str, chat_id: str, path: Path, caption: str = "") -> None:
    if path.stat().st_size > MAX_DOCUMENT_BYTES:
        raise ValueError(f"document exceeds {MAX_DOCUMENT_BYTES} bytes")
    boundary = "----FaseelaTelegramUploadBoundary"
    fields = [("chat_id", chat_id)]
    if caption:
        fields.append(("caption", caption[:900]))
    chunks = []
    for name, value in fields:
        chunks.extend((f"--{boundary}\r\n".encode(), 
                       f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                       value.encode("utf-8"), b"\r\n"))
    filename = path.name.replace('"', "_")
    chunks.extend((
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="document"; filename="{filename}"\r\n'.encode(),
        b"Content-Type: application/octet-stream\r\n\r\n",
        path.read_bytes(), b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ))
    request = Request(
        f"https://api.telegram.org/bot{token}/sendDocument",
        data=b"".join(chunks),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urlopen(request, timeout=45) as response:
        _api_result(response)


def redact(data: bytes) -> bytes:
    for pattern in SECRET_PATTERNS:
        data = pattern.sub(lambda m: (m.group(1) + b"[REDACTED]") if m.lastindex else b"[REDACTED]", data)
    return data


def make_logs_archive(log_dir: Path, destination: Path) -> bool:
    # Only archive bounded text logs. QEMU artifacts may contain large disk
    # images and binary traces; those remain downloadable from GitHub Actions.
    candidates = sorted(
        p for p in log_dir.rglob("*")
        if p.is_file() and not p.is_symlink() and p.suffix.lower() in LOG_SUFFIXES
    )
    selected: list[Path] = []
    total_bytes = 0
    for path in candidates:
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size <= 0 or size > MAX_LOG_FILE_BYTES:
            continue
        if len(selected) >= MAX_LOG_FILES or total_bytes + size > MAX_LOG_ARCHIVE_INPUT_BYTES:
            break
        selected.append(path)
        total_bytes += size
    if not selected:
        return False
    with tarfile.open(destination, "w:gz") as archive:
        for path in selected:
            try:
                data = redact(path.read_bytes())
                info = archive.gettarinfo(str(path), arcname=str(path.relative_to(log_dir)))
                info.size = len(data)
                import io
                archive.addfile(info, io.BytesIO(data))
            except OSError:
                continue
    return destination.exists() and destination.stat().st_size > 0


def _try_send_document(token: str, chat_id: str, path: Path, caption: str) -> bool:
    try:
        send_document(token, chat_id, path, caption)
        return True
    except Exception as exc:
        print(f"::warning::Telegram could not send {path.name} ({type(exc).__name__}); continuing.")
        return False


def deliver_files(token: str, chat_id: str, environ: Mapping[str, str]) -> None:
    run_id = environ.get("GITHUB_RUN_ID", "")
    repository = environ.get("GITHUB_REPOSITORY", "")
    server = environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    run_url = f"{server}/{repository}/actions/runs/{run_id}" if repository and run_id else ""
    report_value = environ.get("TELEGRAM_REPORT_PATH", "").strip()
    report = Path(report_value) if report_value else None
    if report and report.is_file():
        if report.stat().st_size <= MAX_DOCUMENT_BYTES:
            _try_send_document(token, chat_id, report, "تقرير التشغيل الكامل")
        else:
            print("::warning::Telegram report exceeds the document size limit; see GitHub Actions artifacts.")
    logs_value = environ.get("TELEGRAM_LOGS_DIR", "").strip()
    logs = Path(logs_value) if logs_value else None
    if logs and logs.is_dir():
        with tempfile.TemporaryDirectory(prefix="faseela-telegram-") as temp:
            archive = Path(temp) / "faseela-build-logs.tar.gz"
            if make_logs_archive(logs, archive):
                if archive.stat().st_size <= MAX_DOCUMENT_BYTES:
                    _try_send_document(token, chat_id, archive, "سجلات البناء (بعد تنقية بيانات الاعتماد)")
                else:
                    send_message(token, chat_id, "حجم أرشيف السجلات يتجاوز حد Telegram. يمكن تنزيله من صفحة التشغيل: " + run_url)



def main(environ: Mapping[str, str] | None = None) -> int:
    env = os.environ if environ is None else environ
    token = env.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = env.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat_id:
        print("::notice::Telegram notification skipped; configure TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.")
        return 0
    try:
        send_message(token, chat_id, build_message(env))
        deliver_files(token, chat_id, env)
    except (Exception, HTTPError, URLError) as exc:
        # Never print response bodies, request URLs, tokens, or file contents.
        print(f"::warning::Telegram delivery failed ({type(exc).__name__}); workflow result is unchanged.")
        return 0
    print("Telegram report and available files sent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
