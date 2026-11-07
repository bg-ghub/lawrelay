"""Exercise the real adapted analytics proxy route in a network-isolated Caddy.

Requires Docker and uses the immutable Caddy image from compose.production.yml.
No ports are published. Both the proxy and a fake upstream run inside the same
temporary container; no requests reach LawRelay, Umami or other external hosts.
"""

import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
UPSTREAM_MARKER = "isolated-analytics-upstream"


def docker(*arguments, timeout=120, **kwargs):
    return subprocess.run(
        ["docker", *arguments], capture_output=True, text=True,
        encoding="utf-8", timeout=timeout, check=True, **kwargs,
    )


def isolated_config(adapted):
    routes = [
        route
        for server in adapted["apps"]["http"]["servers"].values()
        for route in server.get("routes", [])
        if any(match.get("host") == ["analytics.lawrelay.be"] for match in route.get("match", []))
    ]
    if len(routes) != 1:
        raise AssertionError("Expected exactly one adapted analytics host route")
    route = copy.deepcopy(routes[0])
    replacements = 0

    def substitute_upstream(value):
        nonlocal replacements
        if isinstance(value, dict):
            if value.get("handler") == "reverse_proxy":
                for upstream in value.get("upstreams", []):
                    if upstream.get("dial") == "umami:3000":
                        upstream["dial"] = "127.0.0.1:9081"
                        replacements += 1
            for child in value.values():
                substitute_upstream(child)
        elif isinstance(value, list):
            for child in value:
                substitute_upstream(child)

    substitute_upstream(route)
    if replacements != 1:
        raise AssertionError("Expected exactly one Umami upstream substitution")

    # Retain every adapted production matcher and handler. Only the upstream
    # address and surrounding listeners/TLS are changed for the isolated test.
    return {
        "admin": {"disabled": True},
        "logging": adapted.get("logging", {}),
        "apps": {"http": {"servers": {
            "analytics_test": {
                "listen": [":9080"], "routes": [route],
                "automatic_https": {"disable": True},
            },
            "fake_upstream": {
                "listen": ["127.0.0.1:9081"],
                "automatic_https": {"disable": True},
                "routes": [{"handle": [{
                    "handler": "static_response", "status_code": 200,
                    "headers": {"X-Analytics-Test-Upstream": [UPSTREAM_MARKER]},
                    "body": UPSTREAM_MARKER,
                }]}],
            },
        }}},
    }


class AnalyticsProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compose = (ROOT / "compose.production.yml").read_text(encoding="utf-8")
        image = re.search(r"^  caddy:\s*\n\s+image:\s*(\S+)", compose, re.MULTILINE)
        if not image or "@sha256:" not in image.group(1):
            raise AssertionError("The production Caddy image must be pinned")
        cls.image = image.group(1)
        adapted = docker(
            "run", "--rm", "-i", "--network", "none", cls.image,
            "caddy", "adapt", "--adapter", "caddyfile", "--config", "/dev/stdin",
            input=(ROOT / "config/Caddyfile").read_text(encoding="utf-8"),
        )
        configuration = isolated_config(json.loads(adapted.stdout))
        cls.temporary = tempfile.TemporaryDirectory(prefix="lawrelay-analytics-proxy-")
        cls.addClassCleanup(cls.temporary.cleanup)
        path = Path(cls.temporary.name) / "test.json"
        path.write_text(json.dumps(configuration), encoding="utf-8")
        cls.container = "lawrelay-analytics-proxy-test-" + uuid.uuid4().hex
        docker(
            "run", "-d", "--name", cls.container,
            "--network", "none", "--read-only", "--cap-drop", "ALL",
            "--cap-add", "NET_BIND_SERVICE",
            "--security-opt", "no-new-privileges", "--pids-limit", "64",
            "--memory", "96m", "--cpus", "0.5",
            "--tmpfs", "/config:rw,noexec,nosuid,size=16m",
            "--tmpfs", "/data:rw,noexec,nosuid,size=16m",
            "--mount", f"type=bind,src={path.resolve()},dst=/etc/caddy/test.json,readonly",
            cls.image, "caddy", "run", "--config", "/etc/caddy/test.json",
        )
        cls.addClassCleanup(docker, "rm", "-f", cls.container, timeout=15)
        deadline = time.monotonic() + 30
        last_error = "No successful readiness response"
        while True:
            try:
                status, body, _ = cls.request("/api/heartbeat")
                if status == 200 and body == UPSTREAM_MARKER:
                    break
                last_error = f"Readiness returned status {status} and body {body!r}"
            except (subprocess.CalledProcessError, AssertionError) as error:
                last_error = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
            if time.monotonic() >= deadline:
                logs = docker("logs", cls.container, timeout=10)
                raise AssertionError(
                    "Isolated Caddy did not become ready within 30 seconds: "
                    + last_error + "\n" + logs.stderr[-4000:]
                )
            time.sleep(0.2)

    @classmethod
    def request(cls, path, origin=None, method="GET"):
        command = [
            "exec", cls.container, "wget", "-S", "-O", "-", "-T", "5",
            "--header=Host: analytics.lawrelay.be",
        ]
        if origin is not None:
            command.append("--header=Origin: " + origin)
        if method == "POST":
            command.extend(["--header=Content-Type: application/json", "--post-data={}"])
        command.append("http://127.0.0.1:9080" + path)
        response = docker(*command, timeout=10)
        statuses = re.findall(r"HTTP/\S+\s+(\d{3})", response.stderr)
        if len(statuses) != 1:
            raise AssertionError("Expected a single direct HTTP response")
        return int(statuses[0]), response.stdout, response.stderr

    def test_public_production_collection_reaches_fake_upstream(self):
        for path in ["/api/send", "/api/send/event", "/api/send?test=1"]:
            with self.subTest(path=path):
                status, body, headers = self.request(path, "https://lawrelay.be", "POST")
                self.assertEqual(status, 200)
                self.assertEqual(body, UPSTREAM_MARKER)
                self.assertIn("x-analytics-test-upstream", headers.lower())

    def test_qa_missing_and_nonproduction_origins_do_not_reach_upstream(self):
        for origin in [
            None, "null", "http://localhost:3106", "http://clicks.qa.localhost:3106",
            "https://owner.qa.localhost", "https://lawrelay.test", "http://lawrelay.be",
            "https://admin.lawrelay.be", "https://lawrelay.be.evil.test",
            "https://www.lawrelay.be", "https://lawrelay.be:3106",
        ]:
            for path in ["/api/send", "/api/send/event"]:
                with self.subTest(origin=origin, path=path):
                    status, body, headers = self.request(path, origin, "POST")
                    self.assertEqual(status, 204)
                    self.assertEqual(body, "")
                    self.assertNotIn("x-analytics-test-upstream", headers.lower())

    def test_dashboard_script_and_heartbeat_remain_available(self):
        for path in ["/", "/login", "/websites", "/script.js", "/api/heartbeat", "/api/auth/login"]:
            for origin in [None, "http://clicks.qa.localhost:3106"]:
                with self.subTest(path=path, origin=origin):
                    method = "POST" if path == "/api/auth/login" else "GET"
                    status, body, headers = self.request(path, origin, method)
                    self.assertEqual(status, 200)
                    self.assertEqual(body, UPSTREAM_MARKER)
                    self.assertIn("x-analytics-test-upstream", headers.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
