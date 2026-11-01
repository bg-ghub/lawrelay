#!/usr/bin/env python3
"""Build LawRelay's local address/courthouse index from an OSM PBF.

Run off the production host. Requires osmium==4.3.2 from PyPI. The output
contains public OSM data only; no LawRelay member information is an input.
"""

import argparse
import hashlib
import json
import math
import re
import sqlite3
import unicodedata
from pathlib import Path


def normalize(value):
    value = str(value).casefold().translate(str.maketrans({"œ": "oe", "æ": "ae", "ø": "o", "ł": "l", "đ": "d"}))
    value = unicodedata.normalize("NFKD", value)
    return re.sub(r"[^a-z0-9]", "", value)


def number_key(value):
    return re.sub(r"\s+", "", str(value)).casefold()


def names(tags):
    values = []
    for key in ("name", "name:nl", "name:fr", "name:de", "name:en", "official_name", "alt_name", "short_name"):
        values.extend(part.strip() for part in tags.get(key, "").split(";") if part.strip())
    return list(dict.fromkeys(values))


def building_point(tags, points):
    """Accept only a complete simple convex building; reject other shapes.

    The positive average of all distinct boundary vertices lies inside a
    non-degenerate convex polygon. Directed-edge half-plane checks reject
    concave/self-crossing shapes, so no polygon repair or guessed point occurs.
    Complex buildings can still be represented by precise address nodes/BeSt.
    """
    if tags.get("highway") or tags.get("building", "") in ("", "no", "construction", "ruins", "demolished"):
        return None
    if not points or not 4 <= len(points) <= 65 or points[0] != points[-1]:
        return None
    vertices = points[:-1]
    if len(set(vertices)) != len(vertices):
        return None
    if any(not (math.isfinite(lat) and math.isfinite(lon) and 49.3 <= lat <= 51.7 and 2.3 <= lon <= 6.7) for lat, lon in vertices):
        return None
    orientation = None
    for first, last in zip(points, points[1:]):
        sides = []
        for lat, lon in vertices:
            cross = (last[1]-first[1])*(lat-first[0])-(last[0]-first[0])*(lon-first[1])
            if abs(cross) > 1e-16:
                sides.append(cross > 0)
        if sides:
            if any(side != sides[0] for side in sides):
                return None
            if orientation is not None and orientation != sides[0]:
                return None
            orientation = sides[0]
    if orientation is None:
        return None
    return sum(lat for lat, _ in vertices)/len(vertices), sum(lon for _, lon in vertices)/len(vertices)


def create_schema(database):
    database.executescript("""
      PRAGMA journal_mode = OFF;
      PRAGMA synchronous = OFF;
      CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE addresses (street_key TEXT NOT NULL, number_key TEXT NOT NULL,
        postcode TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
        osm_type TEXT NOT NULL, osm_id INTEGER NOT NULL, city_key TEXT NOT NULL);
      CREATE TABLE street_aliases (street_key TEXT NOT NULL, alias_key TEXT NOT NULL,
        PRIMARY KEY (street_key, alias_key)) WITHOUT ROWID;
      CREATE TABLE courts (name_key TEXT NOT NULL, city_key TEXT NOT NULL,
        latitude REAL NOT NULL, longitude REAL NOT NULL, osm_type TEXT NOT NULL,
        osm_id INTEGER NOT NULL, name TEXT NOT NULL);
    """)


class Writer:
    def __init__(self, database, places=None):
        self.database = database
        self.places = places or {}
        self.addresses = 0
        self.courts = 0
        self.pending = 0

    def add(self, tags, latitude, longitude, kind, osm_id, footprint=None):
        if not (math.isfinite(latitude) and math.isfinite(longitude) and 49.3 <= latitude <= 51.7 and 2.3 <= longitude <= 6.7):
            return
        if tags.get("addr:country", "BE").upper() != "BE":
            return
        if tags.get("highway") and tags.get("name"):
            aliases = names(tags)
            aliases += [part.strip() for part in tags.get("name", "").split(" - ") if part.strip()]
            keys = {normalize(value) for value in aliases if normalize(value)}
            self.database.executemany("INSERT OR IGNORE INTO street_aliases VALUES (?, ?)", ((a, b) for a in keys for b in keys))
        if kind == "way":
            point = building_point(tags, footprint)
            if point is None:
                return
            latitude, longitude = point
        elif tags.get("highway"):
            return
        street = tags.get("addr:street", "").strip()
        postcode = tags.get("addr:postcode", tags.get("is_in:postcode", "")).strip()
        number = tags.get("addr:housenumber", "").strip()
        if street and re.fullmatch(r"\d{4}", postcode) and re.fullmatch(r"\d+[a-zA-Z]?(?:[/\-]\d+[a-zA-Z]?)?", number):
            street_key = normalize(street)
            self.database.execute("INSERT OR IGNORE INTO street_aliases VALUES (?, ?)", (street_key, street_key))
            self.database.execute("INSERT INTO addresses VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                  (street_key, number_key(number), postcode, latitude, longitude, kind, osm_id, normalize(tags.get("addr:city", ""))))
            self.addresses += 1
        is_court = tags.get("amenity") == "courthouse" or tags.get("building") == "courthouse" or tags.get("government") in ("court", "judiciary")
        if is_court:
            court_names = names(tags)
            city = tags.get("addr:city", "").strip()
            city_names = [city] if city else []
            for canonical, translations in self.places.items():
                variants = [canonical, *translations.values()]
                if city and any(normalize(city) == normalize(variant) for variant in variants):
                    city_names += variants
            if not city_names:
                # Only infer a city when it is explicitly part of the mapped
                # name. Never choose a nearby city by distance.
                found = []
                for canonical, translations in self.places.items():
                    variants = [canonical, *translations.values()]
                    if any(re.search(r"\b" + re.escape(variant) + r"\b", name, re.I) for name in court_names for variant in variants):
                        found.append((max(len(variant) for variant in variants), variants))
                if found:
                    longest = max(length for length, _ in found)
                    matches = [variants for length, variants in found if length == longest]
                    if len(matches) == 1:
                        city_names = matches[0]
            for court_name in court_names:
                for city_name in set(city_names):
                    variants = [court_name]
                    if normalize(city_name) not in normalize(court_name):
                        variants.append(f"{court_name} {city_name}")
                    for name in variants:
                        self.database.execute("INSERT INTO courts VALUES (?, ?, ?, ?, ?, ?, ?)",
                            (normalize(name), normalize(city_name), latitude, longitude, kind, osm_id, court_name[:500]))
                        self.courts += 1
        self.pending += 1
        if self.pending >= 20_000:
            self.database.commit()
            self.pending = 0


def build(source, output, places_path):
    import osmium

    if output.exists():
        raise ValueError("Output already exists; build a new file and promote it after checks")
    if not source.is_file() or source.stat().st_size == 0:
        raise ValueError("A complete PBF input is required")
    places = json.loads(places_path.read_text(encoding="utf-8")).get("places", {})
    with sqlite3.connect(output) as database:
        create_schema(database)
        writer = Writer(database, places)

        class Handler(osmium.SimpleHandler):
            def node(self, node):
                relevant = node.tags.get("addr:housenumber") or node.tags.get("amenity") == "courthouse" or node.tags.get("government") in ("court", "judiciary")
                if relevant and node.location.valid():
                    writer.add(dict(node.tags), node.location.lat, node.location.lon, "node", node.id)

            def way(self, way):
                tags = dict(way.tags)
                if not (tags.get("addr:housenumber") or tags.get("highway") or tags.get("amenity") == "courthouse" or tags.get("building") == "courthouse" or tags.get("government") in ("court", "judiciary")):
                    return
                points = [(node.lat, node.lon) for node in way.nodes if node.location.valid()]
                if points:
                    complete = len(points) == len(way.nodes)
                    writer.add(tags, points[0][0], points[0][1], "way", way.id, footprint=points if complete else None)

        # Filter in libosmium before entering Python; the location handler still
        # sees every node so building/road geometries remain complete.
        Handler().apply_file(str(source), locations=True, idx="flex_mem",
                             filters=[osmium.filter.KeyFilter("addr:housenumber", "amenity", "building", "government", "highway")])
        database.execute("CREATE INDEX address_lookup ON addresses (street_key, number_key, postcode)")
        database.execute("CREATE INDEX street_alias_lookup ON street_aliases (alias_key, street_key)")
        database.execute("CREATE INDEX court_lookup ON courts (name_key, city_key)")
        digest = hashlib.file_digest(source.open("rb"), "sha256").hexdigest()
        database.executemany("INSERT INTO metadata VALUES (?, ?)", [("schema_version", "1"), ("source_sha256", digest), ("source", "OpenStreetMap / Geofabrik Belgium"), ("license", "ODbL-1.0"), ("osm_number_key_format", "preserve-separators-v1"), ("osm_way_point_rule", "closed-convex-building-interior-v1")])
        database.commit()
        database.execute("PRAGMA optimize")
        if database.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            raise ValueError("Index integrity check failed")
        print(json.dumps({"addresses": writer.addresses, "court_aliases": writer.courts, "bytes": output.stat().st_size, "source_sha256": digest}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--places", type=Path, default=Path("config/courts.be.json"))
    arguments = parser.parse_args()
    build(arguments.source, arguments.output, arguments.places)
