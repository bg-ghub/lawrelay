#!/usr/bin/env python3
"""Extract exact public court address targets from an existing local OSM PBF.

Requires osmium==4.3.2. No HTTP requests, nearest-address selection or SQLite
updates are performed. Output is a new public JSON artifact for a separately
reviewed index import. Old OSM index rows are never declared safe by this tool.

Targets are JSON lists with {index, source, parts: {street, number, postcode,
city}} or reviewed {geocoding_address, source}. Multiple --targets files are
accepted. Street keys ignore case, accents and punctuation; house codes retain
every slash/hyphen and only ignore whitespace/case. Unparsed targets are reported.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import unicodedata


KEY_FORMAT = "preserve-separators-v1"
HOUSE = re.compile(r"\d+[a-z]*(?:[-/](?:\d+[a-z]*|[a-z]+))*\Z", re.I)
NAME_KEYS = ("name", "name:nl", "name:fr", "name:de", "name:en", "official_name", "alt_name", "short_name")
KEEP_TAGS = (*NAME_KEYS, "amenity", "building", "government", "addr:street", "addr:housenumber",
             "addr:postcode", "addr:city", "addr:country", "addr:unit", "addr:flats", "ref")
MAX_TARGET_BYTES = 10_000_000
MAX_TARGETS = 20_000
MAX_WAY_NODES = 20_000


def normalize(value):
    value = str(value).casefold().translate(str.maketrans({"œ": "oe", "æ": "ae", "ø": "o", "ł": "l", "đ": "d"}))
    return re.sub(r"[^a-z0-9]", "", unicodedata.normalize("NFKD", value))


def number_key(value):
    return re.sub(r"\s+", "", str(value)).casefold()


def valid_number(value):
    return bool(HOUSE.fullmatch(number_key(value)))


def address_parts(value):
    """Parse only an unambiguous literal address; never drop a box or range."""
    value = " ".join(str(value).split())
    if re.search(r"\b(?:bus|bo[iî]te|box|bte|lokaal|floor|[eé]tage|verdieping)\b", value, re.I):
        return None
    match = re.fullmatch(r"(.+?)\s*[,;]?\s+(\d{4})\s+(.+)", value)
    if not match:
        return None
    street = re.fullmatch(r"(.+?)\s+([0-9]+\s*[A-Za-z]*(?:\s*[-/]\s*(?:[0-9]+\s*[A-Za-z]*|[A-Za-z]+))*)\s*[,;]?", match[1].strip())
    if not street or not valid_number(street[2]):
        return None
    return {"street": street[1], "number": street[2], "postcode": match[2], "city": match[3].strip(", ")}


@dataclass(frozen=True)
class Target:
    target_id: str
    street_key: str
    number_key: str
    postcode: str
    city_key: str
    source: str
    court_names: tuple = ()

    @property
    def key(self):
        return self.street_key, self.number_key, self.postcode


def load_targets(paths):
    targets, skipped, sources = [], [], []
    for path in paths:
        if not path.is_file() or path.stat().st_size > MAX_TARGET_BYTES:
            raise ValueError("Expected a bounded public JSON target file")
        content = path.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        sources.append({"name": path.name, "sha256": digest})
        records = json.loads(content)
        if isinstance(records, dict):
            records = records.get("records")
        if not isinstance(records, list) or len(records) > MAX_TARGETS:
            raise ValueError("Targets must be a bounded JSON list")
        for ordinal, record in enumerate(records):
            if not isinstance(record, dict):
                raise ValueError("Each target must be a JSON object")
            index = record.get("index", ordinal)
            target_id = f"{path.name}:{index}:{ordinal}"
            source = record.get("source") or record.get("source_url") or ""
            literal = record.get("geocoding_address") or record.get("address") or ""
            # An explicit reviewed geocoding address supersedes parsed parts.
            parts = address_parts(literal) if record.get("geocoding_address") else record.get("parts")
            if not parts:
                parts = address_parts(literal)
            if not isinstance(parts, dict):
                skipped.append({"target_id": target_id, "index": index, "reason": "unparsed_literal_address"})
                continue
            street = normalize(parts.get("street", ""))
            number = number_key(parts.get("number", ""))
            postcode = str(parts.get("postcode", "")).strip()
            if not street or not HOUSE.fullmatch(number) or not re.fullmatch(r"\d{4}", postcode):
                skipped.append({"target_id": target_id, "index": index, "reason": "invalid_exact_address_parts"})
                continue
            names = record.get("court_names", [])
            if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
                raise ValueError("court_names must contain explicit public court names")
            targets.append(Target(target_id, street, number, postcode, normalize(parts.get("city", "")),
                                  str(source), tuple(normalize(name) for name in names if normalize(name))))
    if not targets:
        raise ValueError("No valid exact public address targets")
    if len(targets) > MAX_TARGETS:
        raise ValueError("Too many target addresses")
    return targets, skipped, sources


def valid_point(latitude, longitude):
    return (math.isfinite(latitude) and math.isfinite(longitude)
            and 49.3 <= latitude <= 51.7 and 2.3 <= longitude <= 6.7)


def polygon_point(points):
    """Use an actual building polygon, never a street or locality centroid.

    The area centroid is used when inside the polygon. For a concave footprint
    whose centroid lies outside, use an actual edge midpoint on the building.
    A missing, open, degenerate or out-of-bounds geometry is rejected.
    """
    if len(points) < 4 or len(points) > MAX_WAY_NODES or points[0] != points[-1]:
        return None
    if any(not valid_point(lat, lon) for lat, lon in points):
        return None
    # Work relative to one vertex to avoid cancellation at Belgium's longitude.
    origin_lat, origin_lon = points[0]
    plane = [(lon-origin_lon, lat-origin_lat) for lat, lon in points]
    area2, xsum, ysum = 0.0, 0.0, 0.0
    for (x1, y1), (x2, y2) in zip(plane, plane[1:]):
        cross = x1*y2-x2*y1
        area2 += cross
        xsum += (x1+x2)*cross
        ysum += (y1+y2)*cross
    if abs(area2) < 1e-16:
        return None
    x, y = xsum/(3*area2), ysum/(3*area2)
    inside = False
    for (x1, y1), (x2, y2) in zip(plane, plane[1:]):
        if (y1 > y) != (y2 > y) and x < (x2-x1)*(y-y1)/(y2-y1)+x1:
            inside = not inside
    if inside:
        return origin_lat+y, origin_lon+x, "building_polygon_centroid"
    for first, second in zip(points, points[1:]):
        if first != second:
            return (first[0]+second[0])/2, (first[1]+second[1])/2, "building_polygon_edge_midpoint"
    return None


def is_court(tags):
    return (tags.get("amenity") == "courthouse" or tags.get("building") == "courthouse"
            or tags.get("government") in {"court", "judiciary"})


def stable_id(kind, source_id):
    return int.from_bytes(hashlib.blake2b(f"OSM:{kind}:{source_id}".encode(), digest_size=8).digest(), "big") & ((1 << 63)-1)


class Collector:
    def __init__(self, targets):
        self.lookup = {}
        self.court_lookup = {}
        for target in targets:
            self.lookup.setdefault(target.key, []).append(target)
            for name in target.court_names:
                self.court_lookup.setdefault((target.street_key, target.postcode, name), []).append(target)
        self.rows = []
        self.court_pois = []
        self.pending_ways = []
        self.geometry_rejections = []

    def matches(self, tags):
        if tags.get("addr:country", "BE").upper() != "BE":
            return [], []
        street = normalize(tags.get("addr:street", ""))
        number = number_key(tags.get("addr:housenumber", ""))
        postcode = tags.get("addr:postcode", "").strip()
        if not street or not re.fullmatch(r"\d{4}", postcode):
            return [], []
        matches = self.lookup.get((street, number, postcode), []) if HOUSE.fullmatch(number) else []
        court_targets = []
        if is_court(tags):
            for key in NAME_KEYS:
                # Semicolon separates explicit names, never address numbers.
                for name in tags.get(key, "").split(";"):
                    court_targets.extend(self.court_lookup.get((street, postcode, normalize(name)), []))
        return matches, list(dict.fromkeys(court_targets))

    def add_point(self, tags, latitude, longitude, kind, source_id, method, matches=None):
        if not valid_point(latitude, longitude):
            return
        address_targets, court_targets = self.matches(tags) if matches is None else matches
        public_tags = {key: tags[key] for key in KEEP_TAGS if key in tags}
        common = {"latitude": latitude, "longitude": longitude, "source_osm_type": kind,
                  "source_osm_id": source_id, "point_method": method, "raw_tags": public_tags}
        if address_targets:
            self.rows.append({**common, "street_key": normalize(tags["addr:street"]),
                              "number_key": number_key(tags["addr:housenumber"]),
                              "postcode": tags["addr:postcode"].strip(),
                              "city_key": normalize(tags.get("addr:city", "")),
                              "osm_type": "osm_exact", "osm_id": stable_id(kind, source_id),
                              "matched_target_ids": sorted(target.target_id for target in address_targets)})
        if court_targets:
            self.court_pois.append({**common, "matched_target_ids": sorted(target.target_id for target in court_targets),
                                    "review_required": True,
                                    "evidence": "Exact explicit court name, street and postcode on an OSM courthouse object. Not imported as an address row without an exact house code."})

    def node(self, source_id, tags, latitude, longitude):
        self.add_point(tags, latitude, longitude, "node", source_id, "address_node")

    def way(self, source_id, tags, refs):
        matches = self.matches(tags)
        if not any(matches):
            return
        # A named road carrying an address must never become a premise point.
        building = tags.get("building", "")
        if not building or building in {"no", "construction", "ruins", "demolished"} or len(refs) < 4 or refs[0] != refs[-1] or len(refs) > MAX_WAY_NODES:
            self.geometry_rejections.append({"source_osm_type": "way", "source_osm_id": source_id,
                                             "reason": "not_a_bounded_current_building_polygon"})
            return
        self.pending_ways.append((source_id, tags, refs, matches))

    def finish_ways(self, locations):
        for source_id, tags, refs, matches in self.pending_ways:
            if any(ref not in locations for ref in refs):
                self.geometry_rejections.append({"source_osm_type": "way", "source_osm_id": source_id,
                                                 "reason": "incomplete_building_geometry"})
                continue
            point = polygon_point([locations[ref] for ref in refs])
            if point is None:
                self.geometry_rejections.append({"source_osm_type": "way", "source_osm_id": source_id,
                                                 "reason": "invalid_building_geometry"})
                continue
            self.add_point(tags, point[0], point[1], "way", source_id, point[2], matches)


def extract(source, output, target_paths):
    import osmium

    if output.exists():
        raise ValueError("Output already exists; choose a new artifact path")
    if not source.is_file() or source.stat().st_size == 0:
        raise ValueError("A complete existing local OSM source is required")
    targets, skipped, input_sources = load_targets(target_paths)
    collector = Collector(targets)

    class FirstPass(osmium.SimpleHandler):
        def node(self, node):
            if node.location.valid():
                collector.node(node.id, dict(node.tags), node.location.lat, node.location.lon)

        def way(self, way):
            tags = dict(way.tags)
            if any(collector.matches(tags)):
                collector.way(way.id, tags, [node.ref for node in way.nodes])

    # Every accepted row/POI requires an explicit matching postcode. Apply this
    # safe filter in libosmium before entering Python for millions of buildings.
    postcodes = sorted({target.postcode for target in targets})
    FirstPass().apply_file(str(source), filters=[osmium.filter.TagFilter(*[("addr:postcode", value) for value in postcodes])])
    print(json.dumps({"phase": "address_objects", "matched_node_rows": len(collector.rows),
                      "candidate_buildings": len(collector.pending_ways)}), flush=True)
    refs = {ref for _, _, nodes, _ in collector.pending_ways for ref in nodes}
    locations = {}
    if refs:
        # Only retain the handful of actual matched-building vertices. A full
        # national in-memory location index is unnecessary for this extraction.
        for node in osmium.FileProcessor(str(source), entities=osmium.osm.NODE).with_filter(osmium.filter.IdFilter(refs)):
            if node.location.valid():
                locations[node.id] = node.location.lat, node.location.lon
        collector.finish_ways(locations)
    with source.open("rb") as handle:
        source_sha256 = hashlib.file_digest(handle, "sha256").hexdigest()
    matched = {target_id for row in collector.rows for target_id in row["matched_target_ids"]}
    result = {"schema_version": 1, "source": "OpenStreetMap / Geofabrik Belgium",
              "source_url": "https://download.geofabrik.de/europe/belgium.html", "license": "ODbL-1.0",
              "source_sha256": source_sha256, "source_bytes": source.stat().st_size,
              "osm_exact_number_key_format": KEY_FORMAT, "target_sources": input_sources,
              "targets_sha256": hashlib.sha256(json.dumps(input_sources, sort_keys=True).encode()).hexdigest(),
              "targets": [{"target_id": target.target_id, "street_key": target.street_key,
                           "number_key": target.number_key, "postcode": target.postcode,
                           "city_key": target.city_key, "source_url": target.source} for target in targets],
              "rows": sorted(collector.rows, key=lambda row: (row["source_osm_type"], row["source_osm_id"])),
              "court_pois": collector.court_pois,
              "unmatched_target_ids": sorted(target.target_id for target in targets if target.target_id not in matched),
              "skipped_targets": skipped, "geometry_rejections": collector.geometry_rejections}
    output.parent.mkdir(parents=True, exist_ok=True)
    # An exclusive temporary file plus replace avoids publishing partial JSON.
    temporary = output.with_name(output.name+".building")
    created_temporary = False
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            created_temporary = True
            json.dump(result, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
        # A hard link creates the final name exclusively. Unlike replace(),
        # this cannot overwrite a file that appeared during the build.
        os.link(temporary, output)
        temporary.unlink()
    except Exception:
        if created_temporary and temporary.is_file():
            temporary.unlink()
        raise
    print(json.dumps({"rows": len(result["rows"]), "matched_targets": len(matched),
                      "valid_targets": len(targets), "skipped_targets": len(skipped),
                      "court_pois": len(result["court_pois"]), "source_sha256": source_sha256,
                      "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest()}), flush=True)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--targets", type=Path, action="append", required=True)
    arguments = parser.parse_args()
    extract(arguments.source, arguments.output, arguments.targets)
