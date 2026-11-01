#!/usr/bin/env python3
"""Add explicit BeSt units and optional exact OSM evidence to a NEW index copy."""
import argparse
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3


def valid_record(record):
    if not isinstance(record, dict):
        return False
    return (isinstance(record.get("street_key"), str) and re.fullmatch(r"[a-z0-9]+", record["street_key"]) and
            isinstance(record.get("house_number"), str) and re.fullmatch(r"\d+[a-z]?(?:[/\-]\d+[a-z]?)?", record["house_number"]) and
            isinstance(record.get("box_number"), str) and re.fullmatch(r"[a-z0-9][a-z0-9/\-]{0,39}", record["box_number"]) and
            isinstance(record.get("postcode"), str) and re.fullmatch(r"\d{4}", record["postcode"]) and
            isinstance(record.get("source_id"), str) and 0 < len(record["source_id"]) <= 200 and
            record.get("region") in ("Brussels", "Wallonia", "Flanders") and
            isinstance(record.get("city_keys"), list) and 0 < len(record["city_keys"]) <= 30 and
            all(isinstance(city, str) and re.fullmatch(r"[a-z0-9]+", city) for city in record["city_keys"]) and
            all(isinstance(record.get(name), (int, float)) and math.isfinite(record[name]) for name in ("latitude", "longitude")) and
            49.3 <= record["latitude"] <= 51.7 and 2.3 <= record["longitude"] <= 6.7)


def import_osm(database, path, metadata):
    path = Path(path).resolve()
    if path.stat().st_size > 20_000_000:
        raise ValueError("Targeted OSM evidence is too large")
    source_bytes = path.read_bytes()
    data = json.loads(source_bytes)
    if (not isinstance(data, dict) or data.get("schema_version") != 1 or
            data.get("source_sha256") != metadata.get("source_sha256") or
            data.get("osm_exact_number_key_format") != "preserve-separators-v1" or not isinstance(data.get("rows"), list)):
        raise ValueError("Exact OSM rows must belong to the same indexed PBF source")
    database.execute("DELETE FROM addresses WHERE osm_type='osm_exact'")
    for row in data["rows"]:
        if (not isinstance(row, dict) or row.get("osm_type") != "osm_exact" or
                not isinstance(row.get("street_key"), str) or not re.fullmatch(r"[a-z0-9]+", row["street_key"]) or
                not isinstance(row.get("city_key"), str) or not re.fullmatch(r"[a-z0-9]*", row["city_key"]) or
                not isinstance(row.get("number_key"), str) or len(row["number_key"]) > 50 or not re.fullmatch(r"\d+[a-z]*(?:[/\-][a-z0-9]+)*", row["number_key"]) or
                not isinstance(row.get("postcode"), str) or not re.fullmatch(r"\d{4}", row["postcode"]) or
                not isinstance(row.get("osm_id"), int) or not 0 <= row["osm_id"] < 2**63 or
                not all(isinstance(row.get(name), (int, float)) and math.isfinite(row[name]) for name in ("latitude", "longitude")) or
                not 49.3 <= row["latitude"] <= 51.7 or not 2.3 <= row["longitude"] <= 6.7):
            raise ValueError("Invalid exact OSM row")
        database.execute("INSERT OR IGNORE INTO street_aliases VALUES (?,?)", (row["street_key"], row["street_key"]))
        database.execute("INSERT INTO addresses VALUES (?,?,?,?,?,?,?,?)", tuple(row[name] for name in (
            "street_key", "number_key", "postcode", "latitude", "longitude", "osm_type", "osm_id", "city_key")))
    database.executemany("INSERT OR REPLACE INTO metadata VALUES (?,?)", [
        ("osm_exact_source_sha256", data["source_sha256"]),
        ("osm_exact_number_key_format", "preserve-separators-v1"),
        ("osm_exact_evidence_sha256", hashlib.sha256(source_bytes).hexdigest())])
    return len(data["rows"])


def augment(original, evidence, output, osm_evidence=None):
    original, evidence, output = map(lambda value: Path(value).resolve(), (original, evidence, output))
    partial = output.with_name(output.stem + ".building.sqlite3")
    if output.exists() or partial.exists() or output in (original, evidence):
        raise ValueError("Choose a new output index")
    if evidence.stat().st_size > 20_000_000:
        raise ValueError("Unit evidence is too large")
    source_bytes = evidence.read_bytes()
    data = json.loads(source_bytes)
    if not isinstance(data, dict) or data.get("schema_version") != 1 or not isinstance(data.get("records"), list):
        raise ValueError("Unsupported unit evidence")
    with closing(sqlite3.connect(f"{original.as_uri()}?mode=ro", uri=True)) as source, closing(sqlite3.connect(partial)) as destination:
        metadata = dict(source.execute("SELECT key,value FROM metadata"))
        if (metadata.get("best_source_sha256") != data.get("source_sha256") or
                metadata.get("best_number_key_format") != "preserve-separators-v1"):
            raise ValueError("Unit evidence must belong to the same official BeSt source")
        source.backup(destination)
        destination.execute("DROP TABLE IF EXISTS best_units")
        destination.execute("""CREATE TABLE best_units (
          street_key TEXT,number_key TEXT,box_key TEXT,postcode TEXT,latitude REAL,longitude REAL,
          city_key TEXT,source_id TEXT,PRIMARY KEY(street_key,number_key,box_key,postcode,city_key,source_id)
        ) WITHOUT ROWID""")
        accepted = 0
        for record in data["records"]:
            if not record.get("box_number"):
                continue
            if not valid_record(record):
                raise ValueError("Invalid official unit record")
            for city in record["city_keys"]:
                destination.execute("INSERT OR IGNORE INTO best_units VALUES (?,?,?,?,?,?,?,?)", (
                    record["street_key"], record["house_number"], record["box_number"], record["postcode"],
                    record["latitude"], record["longitude"], city, record["region"] + ":" + record["source_id"]))
            accepted += 1
        destination.executemany("INSERT OR REPLACE INTO metadata VALUES (?,?)", [
            ("best_unit_source_sha256", data["source_sha256"]),
            ("best_unit_evidence_sha256", hashlib.sha256(source_bytes).hexdigest()),
            ("best_unit_rule", "explicit-official-house-box-v1")])
        osm_count = import_osm(destination, osm_evidence, metadata) if osm_evidence else 0
        destination.commit()
        if destination.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Unit index failed integrity check")
    partial.rename(output)
    return {"unit_records": accepted, "osm_exact_rows": osm_count, "output": str(output)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--osm-evidence")
    args = parser.parse_args()
    print(json.dumps(augment(args.input, args.evidence, args.output, args.osm_evidence)), flush=True)
