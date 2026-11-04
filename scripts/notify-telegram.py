#!/usr/bin/env python3
"""Send a best-effort Telegram notification for a Faseela GitHub Actions run."""

from __future__ import annotations

import html
import json
import os
from typing import Mapping
from urllib.request import Request, urlopen


def parse_job_results(raw: str) -> list[tuple[str, str]]:
    """Parse the compact job=result,job=result format passed by a workflow."""
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
    return "success"


def _escape(value: str) -> str:
    return html.escape(value or "—", quote=True)


def build_message(environ: Mapping[str, str]) -> str:
    results = parse_job_results(environ.get("JOB_RESULTS", ""))
    status = overall_status(results)
    labels = {
        "success": ("✅", "نجح التشغيل"),
        "failure": ("❌", "فشل التشغيل"),
        "cancelled": ("⚪", "تم إلغاء التشغيل"),
    }
    icon, title = labels[status]

    repository = environ.get("GITHUB_REPOSITORY", "")
    server = environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    run_id = environ.get("GITHUB_RUN_ID", "")
    run_url = f"{server}/{repository}/actions/runs/{run_id}" if repository and run_id else server
    branch = environ.get("BRANCH_NAME") or environ.get("GITHUB_REF_NAME", "")
    sha = environ.get("GITHUB_SHA", "")[:7]
    attempt = environ.get("GITHUB_RUN_ATTEMPT", "")
    jobs = "\n".join(f"{name}: {result}" for name, result in results) or "no job results"

    return "\n".join(
        (
            f"<b>{icon} Faseela — {title}</b>",
            f"<b>Workflow:</b> <code>{_escape(environ.get('GITHUB_WORKFLOW', ''))}</code>",
            f"<b>Repository:</b> <code>{_escape(repository)}</code>",
            f"<b>Branch:</b> <code>{_escape(branch)}</code>",
            f"<b>Commit:</b> <code>{_escape(sha)}</code>",
            f"<b>Event:</b> <code>{_escape(environ.get('GITHUB_EVENT_NAME', ''))}</code>",
            f"<b>By:</b> <code>{_escape(environ.get('GITHUB_ACTOR', ''))}</code>",
            f"<b>Attempt:</b> <code>{_escape(attempt)}</code>",
            f"<b>Jobs:</b>\n<code>{_escape(jobs)}</code>",
            f'<a href="{_escape(run_url)}">عرض تفاصيل التشغيل على GitHub</a>',
        )
    )


def send_message(token: str, chat_id: str, message: str) -> None:
    payload = {
        "chat_id": chat_id,
        "text": message,
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
        result = json.loads(response.read().decode("utf-8"))
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RuntimeError("Telegram API returned an unsuccessful response")


def main(environ: Mapping[str, str] | None = None) -> int:
    env = os.environ if environ is None else environ
    token = env.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = env.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat_id:
        print("::notice::Telegram notification skipped; configure TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.")
        return 0

    try:
        send_message(token, chat_id, build_message(env))
    except Exception as exc:  # A notification outage must never fail the build.
        print(
            f"::warning::Telegram notification failed ({type(exc).__name__}); "
            "the workflow result is unchanged."
        )
        return 0

    print("Telegram notification sent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
