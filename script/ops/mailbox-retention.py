#!/usr/bin/env python3
"""Conservative IMAP retention for LawRelay's resolved support conversations.

This deliberately knows nothing about mail bodies, subjects, or recipients.  It
only removes old, complete conversations from the explicitly named Resolved
folder (and their linked Sent copies when requested).
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import email
try:  # Production is Linux; this fallback only permits offline tests on Windows.
    import fcntl
except ImportError:  # pragma: no cover
    class _NoFcntl:
        LOCK_EX = LOCK_UN = 0
        @staticmethod
        def flock(*_args): pass
    fcntl = _NoFcntl()
import imaplib
import json
import os
import re
import ssl
import sys
import tempfile
import time
from dataclasses import dataclass
from email.parser import BytesHeaderParser
from email.policy import default
from pathlib import Path

HOST, PORT = "imap.migadu.com", 993
RETENTION_DAYS, MAX_FOLDERS, MAX_MESSAGES = 730, 64, 20000
HEADER_LIMIT = 16384
ID_RE = re.compile(r"^<[^<>\s]+>$")
IDS_RE = re.compile(r"<[^<>\s]+>")
CURRENT_UID = getattr(os, "geteuid", lambda: os.getuid() if hasattr(os, "getuid") else 0)()
POSIX_LOCKS = hasattr(os, "fchmod") and os.name == "posix"


class SafetyError(Exception):
    pass


def fail(kind: str) -> None:
    print("mailbox retention: " + kind, file=sys.stderr)


def protected_regular(path: Path, *, allow_missing: bool = False, trusted_owners: set[int] | None = None) -> os.stat_result | None:
    try:
        stat = path.lstat()
    except FileNotFoundError:
        if allow_missing:
            return None
        raise SafetyError("configuration")
    if not path.is_file() or path.is_symlink() or stat.st_nlink != 1:
        raise SafetyError("configuration")
    owners = trusted_owners if trusted_owners is not None else {CURRENT_UID}
    if stat.st_mode & 0o077 or stat.st_uid not in owners:
        raise SafetyError("configuration")
    return stat


def read_env(path: Path) -> tuple[str, str]:
    protected_regular(path, trusted_owners={0, 1000, CURRENT_UID})
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        raise SafetyError("configuration") from None
    for line in lines:
        if not line or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key not in {"SMTP_USERNAME", "SMTP_PASSWORD"} or key in values:
            continue
        if not value or "\x00" in value:
            raise SafetyError("configuration")
        values[key] = value
    if set(values) != {"SMTP_USERNAME", "SMTP_PASSWORD"}:
        raise SafetyError("configuration")
    return values["SMTP_USERNAME"], values["SMTP_PASSWORD"]


class State:
    def __init__(self, path: Path):
        if not path.is_absolute():
            raise SafetyError("state")
        self.path = path
        self.lock_path = path.with_name(path.name + ".lock")
        self.value: dict = {"version": 1, "folders": {}}

    def _secure_dir(self) -> None:
        parent = self.path.parent
        try:
            stat = parent.lstat()
            if parent.resolve(strict=True) != parent.absolute():
                raise SafetyError("state")
        except OSError:
            raise SafetyError("state") from None
        if parent.is_symlink() or not parent.is_dir() or stat.st_uid != CURRENT_UID or (stat.st_mode & 0o077):
            raise SafetyError("state")

    @contextlib.contextmanager
    def locked(self):
        self._secure_dir()
        fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            protected_regular(self.lock_path)
            if POSIX_LOCKS: os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            self.load()
            yield self
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def load(self) -> None:
        if protected_regular(self.path, allow_missing=True) is None:
            self.value = {"version": 1, "folders": {}}
            return
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
            if value.get("version") != 1 or set(value) != {"version", "folders"} or not isinstance(value["folders"], dict):
                raise ValueError
            for name, entry in value["folders"].items():
                if not isinstance(name, str) or not isinstance(entry, dict) or set(entry) != {"uidvalidity", "messages"}:
                    raise ValueError
                if not isinstance(entry["uidvalidity"], str) or not entry["uidvalidity"].isdigit() or not isinstance(entry["messages"], dict):
                    raise ValueError
                for uid, record in entry["messages"].items():
                    if not isinstance(uid, str) or not uid.isdigit() or not isinstance(record, dict) or set(record) != {"first_seen"}:
                        raise ValueError
                    if parse_state_time(record["first_seen"]) is None:
                        raise ValueError
            self.value = value
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            raise SafetyError("state") from None

    def folder(self, name: str, uidvalidity: str) -> dict:
        folders = self.value["folders"]
        entry = folders.get(name)
        if not isinstance(entry, dict) or entry.get("uidvalidity") != uidvalidity:
            entry = {"uidvalidity": uidvalidity, "messages": {}}
            folders[name] = entry
        if not isinstance(entry.get("messages"), dict):
            raise SafetyError("state")
        return entry

    def save(self) -> None:
        encoded = json.dumps(self.value, sort_keys=True, separators=(",", ":")).encode()
        fd, temporary = tempfile.mkstemp(prefix=self.path.name + ".", dir=self.path.parent)
        try:
            if POSIX_LOCKS: os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as output:
                fd = -1
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            os.chmod(self.path, 0o600)
            if POSIX_LOCKS:
                directory = os.open(self.path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def parse_date(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        parsed = email.utils.parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(dt.timezone.utc)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None


def parse_state_time(value: str | None) -> dt.datetime | None:
    try:
        parsed = dt.datetime.fromisoformat(value or "")
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(dt.timezone.utc)
    except ValueError:
        return None


def parse_internal(value: str) -> dt.datetime | None:
    try:
        return dt.datetime.strptime(value, "%d-%b-%Y %H:%M:%S %z").astimezone(dt.timezone.utc)
    except ValueError:
        return None


def ids(value: str | None) -> tuple[list[str], bool]:
    if not value:
        return [], True
    found = IDS_RE.findall(value)
    return found, bool(found) and "".join(found) == re.sub(r"\s+", "", value)


@dataclass
class Message:
    folder: str
    uid: str
    flags: set[str]
    internal: dt.datetime | None
    date: dt.datetime | None
    message_id: str | None
    refs: list[str]
    valid: bool

    @property
    def node(self) -> str:
        return self.message_id or "#%s:%s" % (self.folder, self.uid)


def uidvalidity(client) -> str:
    response = client.response("UIDVALIDITY")
    data = response[1] if isinstance(response, tuple) and len(response) > 1 else None
    if not data or not data[0]:
        raise SafetyError("protocol")
    value = data[0].decode() if isinstance(data[0], bytes) else str(data[0])
    if not value.isdigit():
        raise SafetyError("protocol")
    return value


def ok(result) -> list:
    status, data = result
    if status != "OK":
        raise SafetyError("protocol")
    return data


def unquote_folder(raw) -> str | None:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    match = re.search(r'(?:"((?:[^"\\]|\\.)*)"|([^ ]+))\s*$', raw)
    if not match:
        return None
    return (match.group(1) if match.group(1) is not None else match.group(2)).replace('\\"', '"')


def folders(client) -> list[str]:
    data = ok(client.list())
    names = []
    for item in data:
        if not item:
            continue
        text = item.decode("utf-8", "replace") if isinstance(item, bytes) else str(item)
        if "\\Noselect" in text:
            continue
        name = unquote_folder(text)
        if name:
            names.append(name)
    if not names or len(set(names)) > MAX_FOLDERS:
        raise SafetyError("protocol")
    return list(dict.fromkeys(names))


def parse_fetch(folder: str, uid: str, data: list) -> Message:
    pair = next((item for item in data if isinstance(item, tuple) and len(item) == 2), None)
    if not pair or not isinstance(pair[1], (bytes, bytearray)) or len(pair[1]) > HEADER_LIMIT:
        return Message(folder, uid, set(), None, None, None, [], False)
    meta = pair[0].decode("ascii", "replace") if isinstance(pair[0], bytes) else str(pair[0])
    match = re.search(r"\bUID (\d+)", meta)
    imap_uid = match.group(1) if match else ""
    flag_match = re.search(r"FLAGS \(([^)]*)\)", meta)
    internal_match = re.search(r'INTERNALDATE "([^"]+)"', meta)
    headers = BytesHeaderParser(policy=default).parsebytes(bytes(pair[1]))
    single = lambda key: headers.get_all(key, [])
    message_ids, dates, reply_headers, reference_headers = single("Message-ID"), single("Date"), single("In-Reply-To"), single("References")
    message_id = message_ids[0].strip() if len(message_ids) == 1 else None
    refs1, refs1ok = ids(reply_headers[0] if len(reply_headers) == 1 else None)
    refs2, refs2ok = ids(reference_headers[0] if len(reference_headers) == 1 else None)
    valid = bool(imap_uid == uid and flag_match is not None and len(message_ids) == len(dates) == 1 and
                 len(reply_headers) <= 1 and len(reference_headers) <= 1 and message_id and ID_RE.fullmatch(message_id) and
                 internal_match and parse_internal(internal_match.group(1)) and parse_date(headers.get("Date")) and
                 refs1ok and refs2ok)
    return Message(folder, uid, set(flag_match.group(1).split()) if flag_match else set(),
                   parse_internal(internal_match.group(1)) if internal_match else None,
                   parse_date(headers.get("Date")), message_id.strip() if message_id else None,
                   refs1 + refs2, valid)


def scan_folder(client, folder: str) -> tuple[str, list[Message]]:
    ok(client.select(folder_argument(folder), readonly=True))
    validity = uidvalidity(client)
    data = ok(client.uid("SEARCH", None, "ALL"))
    tokens = data[0].split() if data and data[0] else []
    if len(tokens) > MAX_MESSAGES:
        raise SafetyError("limit")
    messages = []
    query = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES DATE)])"
    for token in tokens:
        uid = token.decode() if isinstance(token, bytes) else str(token)
        if not uid.isdigit():
            raise SafetyError("protocol")
        messages.append(parse_fetch(folder, uid, ok(client.uid("FETCH", uid, query))))
    return validity, messages


def folder_argument(folder: str) -> str:
    if any(ord(character) < 32 or ord(character) == 127 for character in folder):
        raise SafetyError("protocol")
    if any(character in folder for character in ' "\\'):
        return '"' + folder.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return folder


def scan_all(client, selected: str, sent: str) -> tuple[dict[str, str], list[Message]]:
    names = folders(client)
    if selected not in names or sent not in names:
        raise SafetyError("configuration")
    validities, messages = {}, []
    for name in names:
        valid, found = scan_folder(client, name)
        validities[name] = valid
        messages.extend(found)
        if len(messages) > MAX_MESSAGES:
            raise SafetyError("limit")
    return validities, messages


def components(messages: list[Message]) -> list[list[Message]]:
    parent: dict[str, str] = {}
    def find(node):
        parent.setdefault(node, node)
        if parent[node] != node:
            parent[node] = find(parent[node])
        return parent[node]
    def join(a, b):
        a, b = find(a), find(b)
        if a != b: parent[b] = a
    for message in messages:
        find(message.node)
        for ref in message.refs: join(message.node, ref)
    groups: dict[str, list[Message]] = {}
    for message in messages:
        groups.setdefault(find(message.node), []).append(message)
    return list(groups.values())


def eligible(messages: list[Message], selected: str, sent: str, state: State, validities: dict[str, str], now: dt.datetime) -> tuple[dict[str, list[str]], int]:
    delete: dict[str, list[str]] = {selected: [], sent: []}
    skipped = 0
    resolved_state = state.folder(selected, validities[selected])["messages"]
    present = {selected: set()}
    for message in messages:
        if message.folder in present:
            present[message.folder].add(message.uid)
            resolved_state.setdefault(message.uid, {"first_seen": now.isoformat()})
    for uid in list(resolved_state):
        if uid not in present[selected]: del resolved_state[uid]
    try:
        cutoff = now.replace(year=now.year - 2)
    except ValueError:  # 29 February has no counterpart in a non-leap year.
        cutoff = now.replace(year=now.year - 2, day=28)
    for group in components(messages):
        involved = {m.folder for m in group}
        selected_messages = [m for m in group if m.folder == selected]
        # Only a complete conversation in Resolved plus specifically-linked Sent copies is removable.
        unsafe = (not selected_messages or any(not m.valid or "\\Flagged" in m.flags or "\\Draft" in m.flags or "\\Deleted" in m.flags for m in group) or
                  any(folder not in {selected, sent} for folder in involved))
        # Unknown references may point to activity outside the mailbox: do not infer safety.
        known_ids = {m.message_id for m in messages if m.message_id}
        if any(ref not in known_ids for m in group for ref in m.refs): unsafe = True
        dates = [d for m in group for d in (m.internal, m.date) if d]
        first = []
        for m in group:
            if m.folder != selected:
                continue
            stamp = parse_state_time(resolved_state.get(m.uid, {}).get("first_seen"))
            if not stamp: unsafe = True
            else: first.append(stamp)
        if unsafe:
            # Any activity which means the thread is no longer conclusively closed
            # starts a new closure clock; do not revive an old timestamp later.
            for message in group:
                if message.folder in {selected, sent}:
                    # Resolved is the closure clock.  Sent activity is included
                    # through INTERNALDATE/Date and never gets unrelated state.
                    if message.folder == selected:
                        resolved_state[message.uid] = {"first_seen": now.isoformat()}
        if unsafe or not dates or not first or max(dates + first) > cutoff:
            skipped += len(selected_messages)
            continue
        for message in group:
            if message.folder in delete: delete[message.folder].append(message.uid)
    return {folder: sorted(set(uids), key=int) for folder, uids in delete.items()}, skipped


def capabilities(client) -> set[str]:
    raw = getattr(client, "capabilities", ()) or ()
    return {(x.decode() if isinstance(x, bytes) else str(x)).upper() for x in raw}


def connect(username: str, password: str, timeout: int):
    context = ssl.create_default_context()
    client = imaplib.IMAP4_SSL(HOST, PORT, ssl_context=context, timeout=timeout)
    client.sock.settimeout(timeout)
    ok(client.login(username, password))
    # Migadu can advertise additional capabilities only after authentication.
    client.capabilities = tuple(b" ".join(ok(client.capability())).split())
    return client


def logout(client) -> None:
    try: client.logout()
    except Exception: pass


def signature(message: Message) -> tuple:
    return (message.folder, message.uid, tuple(sorted(message.flags)), message.internal,
            message.date, message.message_id, tuple(message.refs), message.valid)


def refetch_for_write(client, folder: str, uids: list[str], expected: dict[tuple[str, str], Message], validity: str) -> None:
    """Preflight every exact UID after writable SELECT, before any STORE."""
    ok(client.select(folder_argument(folder), readonly=False))
    if uidvalidity(client) != validity:
        raise SafetyError("race")
    query = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES DATE)])"
    for uid in uids:
        if not uid.isdigit():
            raise SafetyError("protocol")
        current = parse_fetch(folder, uid, ok(client.uid("FETCH", uid, query)))
        if signature(current) != signature(expected[(folder, uid)]):
            raise SafetyError("race")


def write_success(path: Path, now: dt.datetime) -> None:
    """Write an opaque health marker only after the full apply completed."""
    State(path)._secure_dir()
    protected_regular(path, allow_missing=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        if POSIX_LOCKS: os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as output:
            fd = -1
            output.write((now.isoformat() + "\n").encode("ascii"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path); os.chmod(path, 0o600)
    finally:
        try: os.close(fd)
        except OSError: pass
        try: os.unlink(temporary)
        except FileNotFoundError: pass


def run(args, *, imap_factory=connect, clock=lambda: dt.datetime.now(dt.timezone.utc)) -> dict[str, int]:
    # The live account uses these two standard, explicitly reviewed folders.
    # Do not turn a misspelled --sent-folder into permission to purge some other box.
    if args.folder != "Support/Resolved" or args.sent_folder != "Sent":
        raise SafetyError("configuration")
    if args.apply and not getattr(args, "success_file", None):
        raise SafetyError("configuration")
    username, password = read_env(Path(args.env_file))
    state = State(Path(args.state_file))
    if args.apply and Path(args.success_file) != state.path.with_name("last-success"):
        raise SafetyError("configuration")
    with state.locked():
        client = None
        try:
            client = imap_factory(username, password, args.timeout)
            validities, messages = scan_all(client, args.folder, args.sent_folder)
            deletes, skipped = eligible(messages, args.folder, args.sent_folder, state, validities, clock())
        finally:
            if client: logout(client)
        wanted = sum(map(len, deletes.values()))
        deleted = 0
        if args.apply:
            client = None
            try:
                client = imap_factory(username, password, args.timeout)
                if wanted and "UIDPLUS" not in capabilities(client):
                    raise SafetyError("capability")
                again_validities, again_messages = scan_all(client, args.folder, args.sent_folder)
                if again_validities != validities:
                    raise SafetyError("race")
                again, _ = eligible(again_messages, args.folder, args.sent_folder, state, again_validities, clock())
                if again != deletes:
                    raise SafetyError("race")
                expected = {(message.folder, message.uid): message for message in again_messages}
                # Writable SELECT and exact refetch are done for every folder before
                # the first STORE. Cross-folder IMAP changes are not atomic, hence
                # failure before this point has no mailbox effect.
                for folder, uids in deletes.items():
                    if uids:
                        refetch_for_write(client, folder, uids, expected, again_validities[folder])
                for folder, uids in deletes.items():
                    if not uids: continue
                    refetch_for_write(client, folder, uids, expected, again_validities[folder])
                    uidset = ",".join(uids)
                    try:
                        ok(client.uid("STORE", uidset, "+FLAGS.SILENT", "(\\Deleted)"))
                        ok(client.uid("EXPUNGE", uidset))
                    except SafetyError:
                        # Only messages we marked in this run are cleared; never use
                        # EXPUNGE/CLOSE or touch an unrelated existing \Deleted flag.
                        try: ok(client.uid("STORE", uidset, "-FLAGS.SILENT", "(\\Deleted)"))
                        except SafetyError: pass
                        raise
                    deleted += len(uids)
                # Preview must never advance the closure clock.  A successful
                # explicit apply persists it, even when no message was eligible.
                state.save()
                write_success(Path(args.success_file), clock())
            finally:
                if client: logout(client)
        return {"folders": len(validities), "messages": len(messages), "eligible": wanted, "deleted": deleted, "skipped": skipped}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Preview old resolved LawRelay support conversations.")
    parser.add_argument("--env-file", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--folder", required=True)
    parser.add_argument("--sent-folder", default="Sent")
    parser.add_argument("--success-file")
    parser.add_argument("--timeout", type=int, default=20)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    try:
        if not POSIX_LOCKS: raise SafetyError("platform")
        if args.timeout < 1 or args.timeout > 120: raise SafetyError("configuration")
        summary = run(args)
    except SafetyError as error:
        fail(str(error))
        return 2
    except (OSError, imaplib.IMAP4.error, ssl.SSLError):
        fail("connection")
        return 2
    except Exception:
        # Do not put mailbox metadata or credentials in scheduler output.
        fail("operational")
        return 2
    print("mailbox retention: mode=%s folders=%d messages=%d eligible=%d deleted=%d skipped=%d" %
          ("apply" if args.apply else "preview", summary["folders"], summary["messages"], summary["eligible"], summary["deleted"], summary["skipped"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
