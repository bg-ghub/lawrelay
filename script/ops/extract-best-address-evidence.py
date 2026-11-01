#!/usr/bin/env python3
"""Extract only requested premises/units from an existing official BeSt ZIP.

This is an offline evidence step, not fuzzy geocoding. Request keys are exact
street aliases, postal codes and house numbers. Every result retains the
official houseNumber/boxNumber relationship and source identifier. The complete
index and original archive are never modified. lxml is optional (faster scan).
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import zipfile

spec = importlib.util.spec_from_file_location("best_addresses", Path(__file__).with_name("import-best-addresses.py"))
best = importlib.util.module_from_spec(spec)
spec.loader.exec_module(best)


def key(value):
    return re.sub(r"\s+", "", str(value)).casefold()


def requested_numbers(value):
    """Include a slash base only for evidence collection, never for matching."""
    number = key(value)
    result = {number, number.split("/", 1)[0]}
    if suffix := re.fullmatch(r"(\d+)[a-z]+", number):
        result.add(suffix[1])
    if endpoints := re.fullmatch(r"(\d+[a-z]*)-(\d+[a-z]*)", number):
        result.update(endpoints.groups())
    return result


def records(source):
    try:
        from lxml import etree
    except ImportError:
        yield from best.records(source, "address")
        return
    tag = f"{{{best.NS['tns']}}}address"
    for _, element in etree.iterparse(source, events=("end",), tag=tag, resolve_entities=False,
                                     no_network=True, load_dtd=False):
        yield element
        element.clear()
        while element.getprevious() is not None:
            del element.getparent()[0]


def selected_record(element, region, streets, municipalities, parts, postal, targets, transformer):
    street_id = best.identifier(element, "com:hasStreetName")
    if street_id not in targets:
        return None
    postcode = best.identifier(element, "com:hasPostalInfo")
    number = key(best.text(element, "com:houseNumber"))
    if (number, postcode) not in targets[street_id]:
        return None
    rows = best.address_rows(element, region, streets, municipalities, parts, postal, transformer)
    if not rows:
        return None
    cities = {row[-1] for row in rows}
    # Slash-separated official postal village names are explicit aliases.
    for name in postal.get(postcode, ()):
        cities.update(best.normalize(part) for part in name.split("/") if best.normalize(part))
    return {"region": region, "source_id": best.identifier(element), "house_number": number,
            "box_number": key(best.text(element, "com:boxNumber")), "postcode": postcode,
            "street_names": list(streets[street_id]), "street_key": rows[0][0],
            "city_keys": sorted(cities), "latitude": rows[0][3], "longitude": rows[0][4],
            "position_specification": best.text(element, "com:position/com:positionSpecification")}


def all_street_names(archive, region):
    """Include historic street spellings for diagnostics, never index import."""
    result = {}
    with best.xml_member(archive, region, "StreetName") as source:
        for element in best.records(source, "streetName"):
            identifier = best.identifier(element)
            result[identifier] = tuple(dict.fromkeys(result.get(identifier, ()) + best.spellings(element)))
    return result


def status_record(element, region, street_names, targets, accepted):
    street_id = best.identifier(element, "com:hasStreetName")
    number = key(best.text(element, "com:houseNumber"))
    postcode = best.identifier(element, "com:hasPostalInfo")
    if street_id not in targets or (number, postcode) not in targets[street_id]:
        return None
    position = element.find("com:position/com:pointGeometry/com:point/com:pos", best.NS)
    return {"region": region, "source_id": best.identifier(element), "street_id": street_id,
            "street_names": list(street_names.get(street_id, ())), "house_number": number,
            "box_number": key(best.text(element, "com:boxNumber")), "postcode": postcode,
            "address_status": best.text(element, "com:addressStatus/com:status"),
            "officially_assigned": best.text(element, "com:officiallyAssigned"),
            "position_specification": best.text(element, "com:position/com:positionSpecification"),
            "position_srs": position.get("srsName") if position is not None else None,
            "position_text": position.text.strip() if position is not None and position.text else None,
            "accepted_by_existing_filter": accepted}


def extract(source_zip, requests_path, output_path, transformer=None, include_statuses=False):
    source_zip, requests_path, output_path = map(lambda value: Path(value).resolve(), (source_zip, requests_path, output_path))
    if output_path.exists() or output_path in (source_zip, requests_path):
        raise ValueError("Choose a new evidence output path")
    requests = json.loads(requests_path.read_text(encoding="utf-8"))
    if not isinstance(requests, list) or len(requests) > 2000:
        raise ValueError("Expected a bounded list of address requests")
    wanted = {}
    for request in requests:
        parts = request.get("parts") or {}
        if not all(isinstance(parts.get(name), str) and parts[name] for name in ("street", "number", "postcode")):
            continue
        if not re.fullmatch(r"\d{4}", parts["postcode"]):
            raise ValueError("Invalid request postcode")
        for number in requested_numbers(parts["number"]):
            wanted.setdefault(parts["street"], set()).add((number, parts["postcode"]))
    if transformer is None:
        from pyproj import Transformer, network
        network.set_network_enabled(False)
        transformer = Transformer.from_crs("EPSG:3812", "EPSG:4326", always_xy=True)
    with source_zip.open("rb") as source:
        source_sha = hashlib.file_digest(source, "sha256").hexdigest()
    results, regions, statuses = [], {}, []
    with zipfile.ZipFile(source_zip) as archive:
        for region in best.REGIONS:
            streets = best.lookup_names(archive, region, "StreetName", "streetName")
            target_names = all_street_names(archive, region) if include_statuses else streets
            targets = {}
            for identifier, names in target_names.items():
                pairs = set().union(*(wanted.get(best.normalize(name), set()) for name in names))
                if pairs:
                    targets[identifier] = pairs
            if not targets:
                regions[region] = {"read": 0, "selected": 0}
                continue
            municipalities = best.lookup_names(archive, region, "Municipality", "municipality")
            parts = best.lookup_names(archive, region, "PartOfMunicipality", "partOfMunicipality", optional=True)
            postal = best.lookup_names(archive, region, "PostalInfo", "postalInfo")
            read, selected = 0, 0
            with best.xml_member(archive, region, "Address") as source:
                for element in records(source):
                    read += 1
                    result = selected_record(element, region, streets, municipalities, parts, postal, targets, transformer)
                    if result:
                        results.append(result)
                        selected += 1
                    if include_statuses:
                        status = status_record(element, region, target_names, targets, bool(result))
                        if status:
                            statuses.append(status)
                    if read % 1_000_000 == 0:
                        print(json.dumps({"region": region, "read": read, "selected": selected}), flush=True)
            regions[region] = {"read": read, "selected": selected}
            print(json.dumps({"region": region, **regions[region]}), flush=True)
    payload = {"schema_version": 1, "source_url": best.SOURCE_URL, "source_sha256": source_sha,
               "requests_sha256": hashlib.sha256(requests_path.read_bytes()).hexdigest(),
               "regions": regions, "records": results}
    if include_statuses:
        payload["diagnostic_status_records"] = statuses
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"records": len(results), "output": str(output_path), "source_sha256": source_sha}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--requests", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--include-statuses", action="store_true", help="Record excluded/historic matches separately; never imports their points")
    arguments = parser.parse_args()
    print(json.dumps(extract(arguments.source, arguments.requests, arguments.output, include_statuses=arguments.include_statuses)), flush=True)
