"""Exercise mailbox-cleanup health signals without network or notifications."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


@unittest.skipIf(os.name == "nt", "Requires POSIX shell commands")
class MailRetentionHealthTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.tools = root / "bin"
        self.tools.mkdir()
        self.volume = root / "volume"
        self.volume.mkdir()
        (self.volume / "production_queue.sqlite3").touch()
        self.backup = root / "backup"
        self.backup.mkdir()
        (self.backup / "last-success").touch()
        self.mail = root / "mail"
        self.mail.mkdir()
        mocks = {
            "curl": "printf '%s' '{\"status\":\"ok\"}'\n",
            "logger": "exit 0\n",
            "docker": 'printf "%s\\n" "$TEST_VOLUME"\n',
            "df": "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 100 10 90 10%% /test\\n'\n",
            "sqlite3": "case \"$*\" in *quick_check*) printf 'ok\\n';; *) printf '0\\n';; esac\n",
        }
        for name, body in mocks.items():
            target = self.tools / name
            target.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            target.chmod(0o700)
        self.environment = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
            LAWRELAY_BASE_URL="https://health.lawrelay.invalid", TEST_VOLUME=str(self.volume),
            LAWRELAY_BACKUP_STATE_DIR=str(self.backup), LAWRELAY_MAIL_RETENTION_STATE_DIR=str(self.mail),
            LAWRELAY_MAIL_RETENTION_MAX_AGE_HOURS="50", LAWRELAY_NOTIFY_DIRECT="false",
            LAWRELAY_DOCKER_CONTAINER="", LAWRELAY_LOG_TAG="lawrelay-health-test")

    def run_health(self):
        script = Path(__file__).with_name("lawrelay-health")
        return subprocess.run(["sh", str(script)], env=self.environment, capture_output=True,
                              text=True, timeout=10, check=False)

    def test_missing_mail_cleanup_marker_is_unhealthy(self):
        result = self.run_health()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("mailbox cleanup success marker is missing", result.stdout)

    def test_successful_cleanup_is_healthy(self):
        (self.mail / "last-success").touch()
        self.assertEqual(0, self.run_health().returncode)

    def test_missed_daily_cleanup_is_unhealthy(self):
        marker = self.mail / "last-success"
        marker.touch()
        old = time.time() - 51 * 60 * 60
        os.utime(marker, (old, old))
        result = self.run_health()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("mailbox cleanup is older than 50h", result.stdout)

    def test_unconfigured_hosts_remain_compatible(self):
        self.environment.pop("LAWRELAY_MAIL_RETENTION_STATE_DIR")
        self.assertEqual(0, self.run_health().returncode)


if __name__ == "__main__":
    unittest.main()
