"""No-network checks for probe validation and synthetic incident isolation."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
specification = importlib.util.spec_from_file_location("external_uptime", pathlib.Path(__file__).with_name("external-uptime.py"))
monitor = importlib.util.module_from_spec(specification)
specification.loader.exec_module(monitor)


class ExternalUptimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.result_path = pathlib.Path(self.temporary.name) / "result.json"
        environment = {
            "UPTIME_RESULT_PATH": str(self.result_path), "GITHUB_REPOSITORY": "bg-ghub/lawrelay",
            "LAWRELAY_ALERT_OWNER": "bg-ghub", "GITHUB_RUN_ID": "1",
        }
        self.environ = mock.patch.dict(os.environ, environment)
        self.environ.start()
        self.addCleanup(self.environ.stop)
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stdout.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)

    def result(self, ok, synthetic=False):
        self.result_path.write_text(json.dumps({
            "synthetic": synthetic, "ok": ok,
            "checks": [{"check": name, "ok": ok} for name in (*monitor.CHECKS, "certificate")],
        }), encoding="utf-8")

    def test_readiness_requires_exact_json_and_content_type(self):
        self.assertTrue(monitor.valid_body("readiness", b'{"status":"ok"}', "application/json"))
        for body, content_type in [(b'{"status":"unavailable"}', "application/json"), (b"ok", "text/plain"), (b"invalid", "application/json")]:
            self.assertFalse(monitor.valid_body("readiness", body, content_type))

    def test_login_requires_locale_and_actual_login_fields(self):
        page = b'<html lang="nl"><title>LawRelay</title><form><input name="email_address"><input type="password"></form></html>'
        self.assertTrue(monitor.valid_body("login", page, "text/html; charset=utf-8"))
        self.assertFalse(monitor.valid_body("login", page.replace(b'type="password"', b'type="text"'), "text/html"))
        self.assertFalse(monitor.valid_body("login", page.replace(b'lang="nl"', b'lang="en"'), "text/html"))

    def test_operations_requires_minimal_healthy_json(self):
        self.assertTrue(monitor.valid_body("operations", b'{"status":"ok"}', "application/json"))
        self.assertFalse(monitor.valid_body("operations", b'{"status":"unavailable"}', "application/json"))
        self.assertFalse(monitor.valid_body("operations", b'{"status":"ok","queue_errors":[]}', "application/json"))

    def test_synthetic_failure_does_not_probe_production(self):
        with mock.patch.dict(os.environ, {"UPTIME_SELF_TEST": "failure"}), mock.patch.object(monitor, "check_endpoint") as endpoint, mock.patch.object(monitor, "check_certificate") as certificate:
            self.assertEqual(monitor.probe(), 1)
        endpoint.assert_not_called()
        certificate.assert_not_called()
        self.assertTrue(json.loads(self.result_path.read_text())["synthetic"])

    def test_new_failure_creates_one_owner_assigned_incident(self):
        self.result(False)
        with mock.patch.object(monitor, "github_request", side_effect=[[], {}]) as api:
            self.assertEqual(monitor.notify(), 0)
        self.assertEqual(api.call_count, 2)
        creation = api.call_args_list[-1].args
        self.assertEqual(creation[:2], ("POST", "/repos/bg-ghub/lawrelay/issues"))
        self.assertEqual(creation[2]["assignees"], ["bg-ghub"])

    def test_identical_failure_does_not_repeat_notifications(self):
        self.result(False)
        signature = "<!-- failing: certificate,homepage,login,operations,readiness -->"
        incident = {"number": 10, "body": monitor.MARKERS[False] + signature}
        with mock.patch.object(monitor, "github_request", return_value=[incident]) as api:
            self.assertEqual(monitor.notify(), 0)
        self.assertEqual(api.call_count, 1)

    def test_recovery_comments_and_closes_matching_incident(self):
        self.result(True)
        with mock.patch.object(monitor, "github_request", side_effect=[[{"number": 10, "body": monitor.MARKERS[False]}], {}, {}]) as api:
            self.assertEqual(monitor.notify(), 0)
        self.assertEqual(api.call_args_list[-1].args[2], {"state": "closed", "state_reason": "completed"})

    def test_synthetic_recovery_does_not_close_real_incident(self):
        self.result(True, synthetic=True)
        with mock.patch.object(monitor, "github_request", return_value=[{"number": 10, "body": monitor.MARKERS[False]}]) as api:
            self.assertEqual(monitor.notify(), 0)
        self.assertEqual(api.call_count, 1)

    def test_destination_cannot_be_changed(self):
        self.result(False)
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "another/repository"}), mock.patch.object(monitor, "github_request") as api:
            with self.assertRaises(ValueError):
                monitor.notify()
        api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
