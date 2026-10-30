#!/usr/bin/env python3
"""Copy the existing WetWijzer country database through a read-only SSH key."""
import hashlib
import pathlib
import subprocess
import tempfile

DIRECTORY = pathlib.Path("/var/lib/lawrelay-geoip")
DATABASE = DIRECTORY / "GeoLite2-City.mmdb"


def main():
    DIRECTORY.mkdir(mode=0o755, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=DIRECTORY, delete=False) as output:
        temporary = pathlib.Path(output.name)
        try:
            subprocess.run([
                "ssh", "-i", "/root/.ssh/lawrelay_geoip_read",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=/root/.ssh/lawrelay_geoip_known_hosts",
                "root@167.233.245.1", "read-geoip",
            ], stdout=output, check=True, timeout=120)
            output.flush()
            data = temporary.read_bytes()
            if not 1_000_000 < len(data) < 100_000_000 or b"\xab\xcd\xefMaxMind.com" not in data[-131072:]:
                raise ValueError("Country database validation failed; keeping the previous copy")
            unchanged = DATABASE.exists() and hashlib.sha256(DATABASE.read_bytes()).digest() == hashlib.sha256(data).digest()
            if unchanged:
                temporary.unlink()
            else:
                temporary.chmod(0o644)
                temporary.replace(DATABASE)
            print("Country database unchanged." if unchanged else "Country database updated.")
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
