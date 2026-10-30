#!/usr/bin/env python3
"""Daily LawRelay-only cleanup on LawRelay's own Umami host. Defaults to a dry run."""
import argparse
import json
import os
import subprocess

SITE = "0322eeb7-1d93-4249-9d97-f136d4213914"
TABLES = (
    "event_data", "session_data", "session_replay_saved", "session_replay",
    "heatmap_event", "revenue", "website_event", "session",
)
CONTAINER = os.environ.get("LAWRELAY_UMAMI_DB_CONTAINER", "lawrelay-umami-db")


def cleanup_sql(apply=False):
    guard = f"""DO $$ BEGIN
IF NOT EXISTS (SELECT 1 FROM website WHERE website_id='{SITE}'
AND domain='lawrelay.be' AND deleted_at IS NULL) THEN
RAISE EXCEPTION 'LawRelay website configuration mismatch'; END IF; END $$;
"""
    statements = ["BEGIN;", "SET LOCAL statement_timeout = '60s';", guard]
    for table in TABLES:
        predicate = f"website_id='{SITE}' AND created_at < now() - interval '90 days'"
        statements.append(f"SELECT '{table}', count(*) FROM {table} WHERE {predicate};")
        if apply:
            statements.append(f"DELETE FROM {table} WHERE {predicate};")
    statements.append("COMMIT;" if apply else "ROLLBACK;")
    return "\n".join(statements)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    config = json.loads(subprocess.check_output(["docker", "inspect", CONTAINER]))[0]
    env = dict(item.split("=", 1) for item in config["Config"]["Env"] if "=" in item)
    subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-U", env["POSTGRES_USER"],
         "-d", env["POSTGRES_DB"], "-v", "ON_ERROR_STOP=1", "-At"],
        input=cleanup_sql(args.apply), text=True, check=True,
    )


if __name__ == "__main__":
    main()
