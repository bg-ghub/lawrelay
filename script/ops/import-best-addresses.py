#!/usr/bin/env python3
"""Augment a COPY of the OSM index with official Belgian BeSt addresses.

Run off-host with pyproj==3.7.2. Input is the official full ZIP from
https://opendata.bosa.be/download/best/best-full-latest.zip (CC BY 4.0).
Nested XML is streamed; the original index and any existing output are never
overwritten. No address is submitted to a remote geocoding service.
"""

import argparse
from contextlib import closing, contextmanager
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import unicodedata
import xml.etree.ElementTree as ET
import zipfile


NS = {"com": "http://fsb.belgium.be/data/common",
      "tns": "http://fsb.belgium.be/mappingservices/FullDownload/v1_00"}
REGIONS = ("Brussels", "Wallonia", "Flanders")
SOURCE_URL = "https://opendata.bosa.be/download/best/best-full-latest.zip"
NUMBER = re.compile(r"\d+[a-zA-Z]?(?:[/\-]\d+[a-zA-Z]?)?\Z")
PREMISE_POSITIONS = frozenset({"entrance", "building", "buildingUnit", "parcel", "plot", "stand",
                               "thoroughfareAccess", "utilityService", "postalDelivery"})


def normalize(value):
    value = str(value).casefold().translate(str.maketrans({"œ": "oe", "æ": "ae", "ø": "o", "ł": "l", "đ": "d"}))
    return re.sub(r"[^a-z0-9]", "", unicodedata.normalize("NFKD", value))


def text(element, path):
    return (element.findtext(path, default="", namespaces=NS) or "").strip()


def identifier(element, path="com:code"):
    return text(element, f"{path}/com:objectIdentifier")


def spellings(element):
    return tuple(dict.fromkeys(node.text.strip() for node in element.findall("com:name/com:spelling", NS)
                               if node.text and node.text.strip()))


@contextmanager
def xml_member(archive, region, kind, optional=False):
    pattern = re.compile(rf"{region}{kind}\d{{8}}\.zip\Z")
    matches = [info for info in archive.infolist() if pattern.fullmatch(info.filename)]
    if not matches and optional:
        yield None
        return
    if len(matches) != 1 or matches[0].file_size > 300_000_000:
        raise ValueError(f"Expected one bounded {region} {kind} archive")
    with zipfile.ZipFile(io.BytesIO(archive.read(matches[0]))) as nested:
        members = nested.infolist()
        if len(members) != 1 or not members[0].filename.endswith(".xml") or members[0].file_size > 9_000_000_000:
            raise ValueError("Expected one bounded XML member")
        with nested.open(members[0]) as source:
            yield source


def records(source, tag, observed=None):
    if source is None:
        return
    root = None
    expected = f"{{{NS['tns']}}}{tag}"
    for event, element in ET.iterparse(source, events=("start", "end")):
        if root is None:
            root = element
        if event != "end":
            continue
        if observed is not None and element.tag == f"{{{NS['tns']}}}timestamp":
            observed["timestamp"] = element.text
        if element.tag == expected:
            yield element
            root.clear()


def lookup_names(archive, region, kind, tag, optional=False):
    result = {}
    with xml_member(archive, region, kind, optional) as source:
        for element in records(source, tag):
            status = text(element, f"com:{tag}Status/com:status")
            if status and status != "current":
                continue
            names = spellings(element)
            if names:
                result[identifier(element)] = names
    return result


def address_rows(element, region, streets, municipalities, parts, postal_names, transformer):
    if text(element, "com:addressStatus/com:status") != "current" or text(element, "com:officiallyAssigned") != "true":
        return []
    names = streets.get(identifier(element, "com:hasStreetName"), ())
    city_names = municipalities.get(identifier(element, "com:hasMunicipality"), ())
    city_names += parts.get(identifier(element, "com:hasPartOfMunicipality"), ())
    postcode = identifier(element, "com:hasPostalInfo")
    city_names += postal_names.get(postcode, ())
    number = re.sub(r"\s+", "", text(element, "com:houseNumber"))
    if not names or not city_names or not re.fullmatch(r"\d{4}", postcode) or not NUMBER.fullmatch(number):
        return []
    position = element.find("com:position/com:pointGeometry/com:point/com:pos", NS)
    if text(element, "com:position/com:positionSpecification") not in PREMISE_POSITIONS:
        return []
    if position is None or not position.text or position.get("srsName") not in (
        "http://www.opengis.net/def/crs/EPSG/0/3812", "urn:ogc:def:crs:EPSG::3812"
    ):
        return []
    try:
        x, y = (float(value) for value in position.text.split())
        if not math.isfinite(x) or not math.isfinite(y):
            return []
        longitude, latitude = transformer.transform(x, y)
    except (ValueError, TypeError, OverflowError):
        return []
    if not (math.isfinite(latitude) and math.isfinite(longitude) and 49.3 <= latitude <= 51.7 and 2.3 <= longitude <= 6.7):
        return []
    source_id = identifier(element)
    if not source_id:
        return []
    numeric_id = int.from_bytes(hashlib.blake2b(f"{region}:{source_id}".encode(), digest_size=8).digest(), "big") & ((1 << 63) - 1)
    # All spellings are linked through aliases. A single canonical street key
    # avoids multiplying rows for bilingual street names.
    street_key = normalize(names[0])
    return [(street_key, number.casefold(), postcode, latitude, longitude, "best", numeric_id, city)
            for city in sorted({normalize(name) for name in city_names if normalize(name)})]


def add_region(database, archive, region, transformer):
    streets = lookup_names(archive, region, "StreetName", "streetName")
    municipalities = lookup_names(archive, region, "Municipality", "municipality")
    parts = lookup_names(archive, region, "PartOfMunicipality", "partOfMunicipality", optional=True)
    postal = lookup_names(archive, region, "PostalInfo", "postalInfo")
    aliases = set()
    for names in streets.values():
        keys = {normalize(name) for name in names if normalize(name)}
        aliases.update((first, second) for first in keys for second in keys)
    database.executemany("INSERT OR IGNORE INTO street_aliases VALUES (?, ?)", sorted(aliases))
    observed = {}
    seen = accepted = 0
    pending = []
    with xml_member(archive, region, "Address") as source:
        for element in records(source, "address", observed):
            seen += 1
            rows = address_rows(element, region, streets, municipalities, parts, postal, transformer)
            accepted += bool(rows)
            pending.extend(rows)
            if len(pending) >= 10_000:
                database.executemany("INSERT OR IGNORE INTO best_import_addresses VALUES (?, ?, ?, ?, ?, ?, ?, ?)", pending)
                database.commit()
                pending.clear()
            if seen % 200_000 == 0:
                print(json.dumps({"region": region, "read": seen, "accepted": accepted}), flush=True)
    database.executemany("INSERT OR IGNORE INTO best_import_addresses VALUES (?, ?, ?, ?, ?, ?, ?, ?)", pending)
    database.commit()
    result = {"read": seen, "accepted": accepted, **observed}
    print(json.dumps({"region": region, **result}), flush=True)
    return result


def publish_staged_rows(database):
    # Repeated apartment/unit points may differ slightly. Keep one actual
    # published point only when every point is within the app's existing
    # collocation tolerance. Truly distinct premises stay ambiguous.
    database.execute("""
      INSERT INTO addresses (street_key,number_key,postcode,latitude,longitude,osm_type,osm_id,city_key)
      SELECT s.street_key,s.number_key,s.postcode,s.latitude,s.longitude,s.osm_type,s.osm_id,s.city_key
      FROM best_import_addresses s JOIN (
        SELECT street_key,number_key,postcode,city_key,MIN(rowid) first_row,
          MAX(latitude)-MIN(latitude) lat_span,MAX(longitude)-MIN(longitude) lon_span
        FROM best_import_addresses GROUP BY street_key,number_key,postcode,city_key
      ) b USING (street_key,number_key,postcode,city_key)
      WHERE (b.lat_span <= 0.00015 AND b.lon_span <= 0.00025 AND s.rowid=b.first_row)
         OR b.lat_span > 0.00015 OR b.lon_span > 0.00025
    """)
    count = database.execute("SELECT COUNT(*) FROM addresses WHERE osm_type='best'").fetchone()[0]
    database.execute("DROP TABLE best_import_addresses")
    return count


def expand_postal_city_aliases(database, archive):
    # Official postal names can group villages, e.g. "GALMAARDEN/Tollembeek".
    # Preserve each published village name without guessing a municipality.
    aliases = set()
    for region in REGIONS:
        with xml_member(archive, region, "PostalInfo") as source:
            for element in records(source, "postalInfo"):
                for name in spellings(element):
                    if "/" in name:
                        aliases.update((identifier(element), normalize(name), normalize(part))
                                       for part in name.split("/") if normalize(part))
    database.execute("CREATE TEMP TABLE best_postal_aliases (postcode,combined,alias,PRIMARY KEY(postcode,combined,alias))")
    database.executemany("INSERT INTO best_postal_aliases VALUES (?,?,?)", sorted(aliases))
    database.execute("""
      INSERT INTO addresses (street_key,number_key,postcode,latitude,longitude,osm_type,osm_id,city_key)
      SELECT a.street_key,a.number_key,a.postcode,a.latitude,a.longitude,a.osm_type,a.osm_id,p.alias
      FROM addresses a JOIN best_postal_aliases p ON p.postcode=a.postcode AND p.combined=a.city_key
      WHERE a.osm_type='best'
    """)
    database.execute("DROP TABLE best_postal_aliases")
    database.execute("INSERT OR REPLACE INTO metadata VALUES ('best_postal_aliases_expanded','1')")


def build(source_zip, original_index, output, transformer=None):
    if transformer is None:
        from pyproj import Transformer, network

        network.set_network_enabled(False)
        transformer = Transformer.from_crs("EPSG:3812", "EPSG:4326", always_xy=True)
    source_zip, original_index, output = (Path(value).resolve() for value in (source_zip, original_index, output))
    partial = output.with_name(output.stem + ".building.sqlite3")
    if output.exists() or partial.exists() or output == original_index:
        raise ValueError("Output/partial must not exist and must differ from the original index")
    if not source_zip.is_file() or not original_index.is_file():
        raise ValueError("Existing source ZIP and original index are required")
    with source_zip.open("rb") as source:
        source_hash = hashlib.file_digest(source, "sha256").hexdigest()
    with closing(sqlite3.connect(f"{original_index.as_uri()}?mode=ro", uri=True)) as original, closing(sqlite3.connect(partial)) as database:
        metadata = dict(original.execute("SELECT key,value FROM metadata"))
        if metadata.get("schema_version") != "1" or not re.fullmatch(r"[0-9a-f]{64}", metadata.get("source_sha256", "")) or "best_source_sha256" in metadata:
            raise ValueError("Expected a finalized, unaugmented OSM index")
        original.backup(database)
        database.executescript("""
          PRAGMA journal_mode=OFF;
          PRAGMA synchronous=OFF;
          PRAGMA cache_size=-65536;
          CREATE TABLE best_import_addresses (street_key TEXT NOT NULL,number_key TEXT NOT NULL,
            postcode TEXT NOT NULL,latitude REAL NOT NULL,longitude REAL NOT NULL,
            osm_type TEXT NOT NULL,osm_id INTEGER NOT NULL,city_key TEXT NOT NULL);
          CREATE UNIQUE INDEX best_import_unique ON best_import_addresses
            (street_key,number_key,postcode,city_key,latitude,longitude);
        """)
        with zipfile.ZipFile(source_zip) as archive:
            stats = {region.lower(): add_region(database, archive, region, transformer) for region in REGIONS}
            publish_staged_rows(database)
            expand_postal_city_aliases(database, archive)
        count = database.execute("SELECT COUNT(*) FROM addresses WHERE osm_type='best'").fetchone()[0]
        if count == 0:
            raise ValueError("No usable official address points were imported")
        database.executemany("INSERT INTO metadata VALUES (?, ?)", [
            ("best_source_sha256", source_hash), ("best_source_url", SOURCE_URL),
            ("best_license", "CC-BY-4.0"), ("best_source_timestamps", json.dumps(stats, sort_keys=True)),
            ("best_number_key_format", "preserve-separators-v1"),
            ("best_address_rows", str(count)),
        ])
        database.commit()
        database.execute("VACUUM")
        database.execute("PRAGMA optimize")
        if database.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            raise ValueError("Augmented index integrity check failed")
    # Same-directory hard linking publishes without overwriting a file created
    # during the build. The private build file is removed only after success.
    os.link(partial, output)
    partial.unlink()
    print(json.dumps({"output": str(output), "best_address_rows": count,
                      "bytes": output.stat().st_size, "best_source_sha256": source_hash}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_zip", type=Path)
    parser.add_argument("original_index", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.source_zip, args.original_index, args.output)
