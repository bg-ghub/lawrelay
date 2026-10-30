"""Public-only probes and a deduplicated private GitHub incident; no app secrets."""
import argparse
import datetime
import html.parser
import json
import os
import pathlib
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "https://lawrelay.be"
CHECKS = {
    "homepage": "/nl", "login": "/nl/session/new", "readiness": "/ready",
    "operations": "/health/operations",
}
MARKERS = {
    False: "<!-- lawrelay-external-uptime -->",
    True: "<!-- lawrelay-external-uptime-self-test -->",
}
MAX_BODY = 512 * 1024


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.language = None
        self.password = False
        self.email = False
        self.form = False
        self.geo_widget = False

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == "html":
            self.language = attributes.get("lang")
        if tag == "form":
            self.form = True
        if tag == "altcha-widget":
            self.geo_widget = True
        if tag == "input":
            self.password |= attributes.get("type") == "password"
            self.email |= attributes.get("name") == "email_address"


def valid_body(name, body, content_type):
    if name in {"readiness", "operations"}:
        if "application/json" not in content_type:
            return False
        try:
            return json.loads(body) == {"status": "ok"}
        except (ValueError, UnicodeError):
            return False
    if "text/html" not in content_type:
        return False
    page = Page()
    try:
        text = body.decode("utf-8")
        page.feed(text)
    except (UnicodeError, ValueError):
        return False
    if page.language != "nl" or "LawRelay" not in text:
        return False
    return name != "login" or (page.form and page.password and page.email)


def check_endpoint(name, path):
    opener = urllib.request.build_opener(
        NoRedirects(), urllib.request.HTTPSHandler(context=ssl.create_default_context())
    )
    for attempt in range(2):
        try:
            request = urllib.request.Request(
                BASE_URL + path, headers={"User-Agent": "LawRelay-external-uptime/1.0"}
            )
            with opener.open(request, timeout=12) as response:
                body = response.read(MAX_BODY + 1)
                if response.status == 200 and len(body) <= MAX_BODY and valid_body(
                    name, body, response.headers.get("content-type", "").lower()
                ):
                    return {"check": name, "ok": True}
        except urllib.error.HTTPError as error:
            # Foreign anonymous probes should reach the intentional security
            # check, not treat its exact local redirect as an outage.
            if name == "homepage" and error.code == 303 and error.headers.get("Location") in {
                "/nl/geo-challenge", BASE_URL + "/nl/geo-challenge",
            }:
                return check_geo_challenge(opener)
        except (OSError, ValueError, urllib.error.URLError):
            pass
        if attempt == 0:
            time.sleep(3)
    return {"check": name, "ok": False}


def check_geo_challenge(opener):
    try:
        request = urllib.request.Request(
            BASE_URL + "/nl/geo-challenge",
            headers={"User-Agent": "LawRelay-external-uptime/1.0"},
        )
        with opener.open(request, timeout=12) as response:
            body = response.read(MAX_BODY + 1)
            page = Page()
            page.feed(body.decode("utf-8"))
            ok = response.status == 200 and len(body) <= MAX_BODY and valid_body(
                "homepage", body, response.headers.get("content-type", "").lower()
            ) and page.form and page.geo_widget
            return {"check": "homepage", "ok": bool(ok)}
    except (OSError, ValueError, urllib.error.URLError):
        return {"check": "homepage", "ok": False}


def check_certificate():
    try:
        context = ssl.create_default_context()
        with socket.create_connection(("lawrelay.be", 443), timeout=12) as connection:
            with context.wrap_socket(connection, server_hostname="lawrelay.be") as secured:
                expires = ssl.cert_time_to_seconds(secured.getpeercert()["notAfter"])
                return {"check": "certificate", "ok": expires - time.time() > 14 * 86400}
    except (OSError, ValueError, KeyError):
        return {"check": "certificate", "ok": False}


def probe():
    mode = os.environ.get("UPTIME_SELF_TEST", "off")
    if mode not in {"off", "failure", "recovery"}:
        raise ValueError("Unsupported synthetic test mode")
    synthetic = mode != "off"
    checks = (
        [{"check": name, "ok": mode == "recovery"} for name in (*CHECKS, "certificate")]
        if synthetic
        else [*(check_endpoint(name, path) for name, path in CHECKS.items()), check_certificate()]
    )
    result = {
        "synthetic": synthetic,
        "ok": all(check["ok"] for check in checks),
        "checks": checks,
        "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    pathlib.Path(os.environ["UPTIME_RESULT_PATH"]).write_text(json.dumps(result), encoding="utf-8")
    summary = "Synthetic alert test" if synthetic else "External LawRelay HTTPS check"
    lines = [f"### {summary}", "", "| Check | Result |", "| --- | --- |"]
    lines.extend(f"| {check['check']} | {'pass' if check['ok'] else 'FAIL'} |" for check in checks)
    print("\n".join(lines))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary_file:
            summary_file.write("\n".join(lines) + "\n")
    return 0 if result["ok"] else 1


def github_request(method, path, body=None):
    request = urllib.request.Request(
        "https://api.github.com" + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            "Content-Type": "application/json",
            "User-Agent": "LawRelay-external-uptime/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=15, context=ssl.create_default_context()) as response:
        return json.load(response)


def notify():
    result = json.loads(pathlib.Path(os.environ["UPTIME_RESULT_PATH"]).read_text(encoding="utf-8"))
    if type(result.get("synthetic")) is not bool or type(result.get("ok")) is not bool:
        raise ValueError("Invalid probe result")
    repo = os.environ["GITHUB_REPOSITORY"]
    owner = os.environ["LAWRELAY_ALERT_OWNER"]
    if repo != "bg-ghub/lawrelay" or owner != "bg-ghub":
        raise ValueError("Unexpected incident destination")
    marker = MARKERS[result["synthetic"]]
    prefix = f"/repos/{repo}"
    issues = []
    page = 1
    while True:
        batch = github_request("GET", f"{prefix}/issues?state=open&per_page=100&page={page}")
        issues.extend(issue for issue in batch if marker in (issue.get("body") or "") and not issue.get("pull_request"))
        if len(batch) < 100:
            break
        page += 1
        if page > 10:
            raise ValueError("Too many open issues for safe incident lookup")
    synthetic = "Synthetic test: " if result["synthetic"] else ""
    run_url = f"https://github.com/{repo}/actions/runs/{int(os.environ['GITHUB_RUN_ID'])}"
    if result["ok"]:
        for issue in issues:
            github_request("POST", f"{prefix}/issues/{issue['number']}/comments", {
                "body": f"{synthetic}All external checks passed again. [Recovery run]({run_url})."
            })
            github_request("PATCH", f"{prefix}/issues/{issue['number']}", {"state": "closed", "state_reason": "completed"})
        print("Recovery recorded; any matching private incident is closed." if issues else "All checks healthy; no open incident.")
        return 0
    failures = sorted(check["check"] for check in result["checks"] if not check["ok"] and check["check"] in (*CHECKS, "certificate"))
    signature = "<!-- failing: " + ",".join(failures) + " -->"
    if issues and signature in issues[0].get("body", ""):
        print("Incident remains open; duplicate notification suppressed.")
        return 0
    body = (
        f"{marker}\n{signature}\n\n"
        f"{synthetic}External HTTPS checks failed: **{', '.join(failures)}**.\n\n"
        f"[Check run]({run_url}). Review the protected server journal and the incident-response runbook. "
        "No account, assignment, email, credential, or response-body data is included.\n\n"
        "This issue is assigned to the operator. GitHub inbox/email delivery depends on the operator's notification settings."
    )
    if issues:
        github_request("PATCH", f"{prefix}/issues/{issues[0]['number']}", {"body": body})
        print("Existing private incident updated with changed failing checks.")
    else:
        github_request("POST", f"{prefix}/issues", {
            "title": synthetic + "LawRelay external uptime check failed",
            "body": body,
            "assignees": [owner],
        })
        print("One private incident opened and assigned to the operator.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("probe", "notify"))
    arguments = parser.parse_args()
    try:
        sys.exit(probe() if arguments.action == "probe" else notify())
    except Exception as error:
        # Do not print API responses, credentials, endpoint bodies or message contents.
        print(f"Uptime {arguments.action} failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(2)
