#!/usr/bin/env python3
"""Offline tests for the Faseela Telegram notifier."""
from __future__ import annotations

import importlib.util
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "notify-telegram.py"
SPEC = importlib.util.spec_from_file_location("notify_telegram", SCRIPT)
assert SPEC and SPEC.loader
notify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notify)


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self):
        return b'{"ok": true, "result": {"message_id": 1}}'


class TelegramNotifierTests(unittest.TestCase):
    def test_failure_takes_precedence_over_cancelled(self):
        self.assertEqual(notify.overall_status([("core", "failure"), ("build", "cancelled")]), "failure")

    def test_timeout_is_failure(self):
        self.assertEqual(notify.overall_status([("core", "timed_out")]), "failure")

    def test_skipped_optional_jobs_do_not_fail_a_successful_run(self):
        self.assertEqual(notify.overall_status([("core", "success"), ("image", "skipped")]), "success")

    def test_running_status_is_reported(self):
        self.assertEqual(notify.overall_status([("core", "in_progress")]), "running")

    def test_start_phase_reports_that_build_has_started(self):
        message = notify.build_message({"TELEGRAM_PHASE": "started", "JOB_RESULTS": ""})
        self.assertIn("بدأ البناء", message)

    def test_message_contains_detailed_metadata_and_escapes_html(self):
        message = notify.build_message({
            "GITHUB_REPOSITORY": "owner/repo", "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_NUMBER": "45", "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_WORKFLOW": "Build <ISO>", "BRANCH_NAME": "feature/<test>",
            "GITHUB_SHA": "abcdef0123456789", "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_ACTOR": "alice&bob", "JOB_RESULTS": "core=success,build=failure",
            "PR_NUMBER": "188",
        })
        self.assertIn("Build &lt;ISO&gt;", message)
        self.assertIn("feature/&lt;test&gt;", message)
        self.assertIn("alice&amp;bob", message)
        self.assertIn("build: failure", message)
        self.assertIn("Attempt:</b> <code>2", message)
        self.assertIn("Run:</b> <code>#45", message)
        self.assertIn("Pull request:</b> <code>#188", message)
        self.assertIn("https://github.com/owner/repo/actions/runs/123", message)

    def test_message_links_to_release_when_available(self):
        message = notify.build_message({
            "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "123",
            "TELEGRAM_RELEASE_URL": "https://github.com/owner/repo/releases/tag/v1",
        })
        self.assertIn("https://github.com/owner/repo/releases/tag/v1", message)
        self.assertIn("تنزيل ملفات البناء", message)

    def test_message_falls_back_to_actions_artifacts_without_release(self):
        message = notify.build_message({
            "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "123",
        })
        self.assertIn("ملفات البناء (Artifacts)", message)
        self.assertIn("https://github.com/owner/repo/actions/runs/123", message)

    def test_sends_html_message_and_disables_link_previews(self):
        with patch.object(notify, "urlopen", return_value=FakeResponse()) as opener:
            notify.send_message("123:token", "-100123", "<b>Faseela</b>")
        request = opener.call_args.args[0]
        self.assertEqual(request.method, "POST")
        self.assertTrue(request.full_url.endswith("/sendMessage"))
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual(payload["chat_id"], "-100123")
        self.assertEqual(payload["parse_mode"], "HTML")
        self.assertTrue(payload["link_preview_options"]["is_disabled"])

    def test_sends_document_as_multipart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "build.log"
            path.write_text("log content")
            with patch.object(notify, "urlopen", return_value=FakeResponse()) as opener:
                notify.send_document("123:token", "-100123", path, "Build log")
        request = opener.call_args.args[0]
        self.assertTrue(request.full_url.endswith("/sendDocument"))
        self.assertIn(b'name="document"; filename="build.log"', request.data)
        self.assertIn(b"log content", request.data)
        self.assertIn(b"Build log", request.data)

    def test_log_archive_redacts_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "logs"
            root.mkdir()
            (root / "build.log").write_text("Authorization: Bearer abcdefghijklmnop\npassword=hunter2\n")
            archive_path = Path(tmp) / "logs.tar.gz"
            self.assertTrue(notify.make_logs_archive(root, archive_path))
            with tarfile.open(archive_path, "r:gz") as archive:
                content = archive.extractfile("build.log").read()
            self.assertIn(b"[REDACTED]", content)
            self.assertNotIn(b"hunter2", content)
            self.assertNotIn(b"abcdefghijklmnop", content)

    def test_missing_secrets_skip_without_network_access(self):
        with patch.object(notify, "urlopen") as opener:
            self.assertEqual(notify.main({}), 0)
        opener.assert_not_called()


if __name__ == "__main__":
    unittest.main()
