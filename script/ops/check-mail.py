"""Inspect only the synthetic launch-check message, without printing mailbox data."""
import email
import imaplib
from pathlib import Path

settings = {}
for line in (Path(__file__).resolve().parents[2] / ".env.production.local").read_text().splitlines():
    key, separator, value = line.partition("=")
    if separator and key in ("SMTP_USERNAME", "SMTP_PASSWORD"):
        settings[key] = value

try:
    with imaplib.IMAP4_SSL("imap.migadu.com", 993) as mailbox:
        mailbox.login(settings["SMTP_USERNAME"], settings["SMTP_PASSWORD"])
        mailbox.select("INBOX", readonly=True)
        status, matches = mailbox.uid("search", None, 'HEADER Subject "LawRelay launch sender check"')
        message_ids = matches[0].split()
        if status != "OK" or not message_ids:
            raise RuntimeError("Synthetic launch check has not arrived")
        status, response = mailbox.uid("fetch", message_ids[-1], "(BODY.PEEK[HEADER.FIELDS (AUTHENTICATION-RESULTS)])")
        if status != "OK":
            raise RuntimeError("Could not inspect the launch-check authentication headers")
        headers = email.message_from_bytes(response[0][1])
        authentication = " ".join(headers.get_all("Authentication-Results", [])).lower()
        print("Synthetic launch check received in info@ / admin@ inbox")
        for check in ("spf", "dkim", "dmarc"):
            print(f"{check.upper()} alignment: {'pass' if f'{check}=pass' in authentication else 'not confirmed'}")
except Exception as error:
    raise SystemExit(f"Mail check failed: {type(error).__name__}") from None
