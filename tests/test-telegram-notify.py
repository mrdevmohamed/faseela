#!/usr/bin/env python3
"""Offline tests for the Faseela Telegram notifier."""

from __future__ import annotations

import importlib.util
import json
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
        results = [("core", "failure"), ("build", "cancelled")]
        self.assertEqual(notify.overall_status(results), "failure")

    def test_timeout_is_failure(self):
        self.assertEqual(notify.overall_status([("core", "timed_out")]), "failure")

    def test_skipped_optional_jobs_do_not_fail_a_successful_run(self):
        results = [("core", "success"), ("image", "skipped"), ("release", "skipped")]
        self.assertEqual(notify.overall_status(results), "success")

    def test_message_escapes_workflow_metadata(self):
        message = notify.build_message(
            {
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_RUN_ID": "123",
                "GITHUB_RUN_ATTEMPT": "2",
                "GITHUB_WORKFLOW": "Build <ISO>",
                "BRANCH_NAME": "feature/<test>",
                "GITHUB_SHA": "abcdef0123456789",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_ACTOR": "alice&bob",
                "JOB_RESULTS": "core=success,build=failure",
            }
        )
        self.assertIn("Build &lt;ISO&gt;", message)
        self.assertIn("feature/&lt;test&gt;", message)
        self.assertIn("alice&amp;bob", message)
        self.assertIn("build: failure", message)
        self.assertIn("Attempt:</b> <code>2", message)
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

    def test_missing_secrets_skip_without_network_access(self):
        with patch.object(notify, "urlopen") as opener:
            self.assertEqual(notify.main({}), 0)
        opener.assert_not_called()


if __name__ == "__main__":
    unittest.main()
