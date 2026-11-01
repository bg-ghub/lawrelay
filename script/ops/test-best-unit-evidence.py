#!/usr/bin/env python3
from contextlib import closing
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import xml.etree.ElementTree as ET


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


extract = load("unit_extract", "extract-best-address-evidence.py")
augment = load("unit_import", "import-best-unit-evidence.py")
fixtures = load("best_fixtures", "test-best-addresses.py")


class UnitEvidenceTest(unittest.TestCase):
    def test_exact_relationship_is_retained_without_joining_house_digits(self):
        xml = fixtures.address(number="10/2").replace("<com:houseNumber>10/2</com:houseNumber>",
            "<com:houseNumber>10/2</com:houseNumber><com:boxNumber> 003 A </com:boxNumber>")
        record = extract.selected_record(ET.fromstring(xml), "Brussels", {"street": ("Teststraat",)},
            {"city": ("Brussel",)}, {}, {}, {"street": {("10/2", "1000")}}, fixtures.Transformer())
        self.assertEqual("10/2", record["house_number"])
        self.assertEqual("003a", record["box_number"])
        self.assertEqual("1", record["source_id"])
        self.assertIsNone(extract.selected_record(ET.fromstring(xml), "Brussels", {"street": ("Teststraat",)},
            {"city": ("Brussel",)}, {}, {}, {"street": {("102", "1000")}}, fixtures.Transformer()))

    def test_only_current_official_premise_positions_are_evidence(self):
        for xml in (fixtures.address(status="retired"), fixtures.address(official="false"), fixtures.address(position="street")):
            self.assertIsNone(extract.selected_record(ET.fromstring(xml), "Brussels", {"street": ("Teststraat",)},
                {"city": ("Brussel",)}, {}, {}, {"street": {("13", "1000")}}, fixtures.Transformer()))

    def test_excluded_or_retired_statuses_are_diagnostic_only_not_importable_points(self):
        element = ET.fromstring(fixtures.address(status="retired", position="street"))
        record = extract.status_record(element, "Brussels", {"street": ("Teststraat",)},
            {"street": {("13", "1000")}}, accepted=False)
        self.assertEqual("retired", record["address_status"])
        self.assertEqual("street", record["position_specification"])
        self.assertFalse(record["accepted_by_existing_filter"])
        self.assertNotIn("latitude", record)
        self.assertFalse(augment.valid_record(record))

    def test_a_new_index_retains_source_relationships_and_input_is_immutable(self):
        with tempfile.TemporaryDirectory() as directory:
            original, evidence, output = (Path(directory) / filename for filename in ("original.sqlite3", "evidence.json", "units.sqlite3"))
            with closing(sqlite3.connect(original)) as database:
                database.execute("CREATE TABLE metadata(key PRIMARY KEY,value)")
                database.executemany("INSERT INTO metadata VALUES (?,?)", [
                    ("best_source_sha256", "a" * 64), ("best_number_key_format", "preserve-separators-v1")])
                database.commit()
            record = {"street_key": "teststraat", "house_number": "13", "box_number": "0005", "postcode": "1000",
                      "latitude": 50.85, "longitude": 4.35, "city_keys": ["brussel", "bruxelles"], "source_id": "unit-1", "region": "Brussels"}
            evidence.write_text(json.dumps({"schema_version": 1, "source_sha256": "a" * 64, "records": [record]}))
            before = hashlib.sha256(original.read_bytes()).hexdigest()
            result = augment.augment(original, evidence, output)
            self.assertEqual(1, result["unit_records"])
            self.assertEqual(before, hashlib.sha256(original.read_bytes()).hexdigest())
            with closing(sqlite3.connect(output)) as database:
                rows = database.execute("SELECT number_key,box_key,city_key,source_id FROM best_units ORDER BY city_key").fetchall()
                self.assertEqual([("13", "0005", "brussel", "Brussels:unit-1"), ("13", "0005", "bruxelles", "Brussels:unit-1")], rows)
            with self.assertRaises(ValueError):
                augment.augment(original, evidence, output)

    def test_wrong_dataset_or_invalid_coordinates_are_never_published(self):
        with tempfile.TemporaryDirectory() as directory:
            original, evidence, output = (Path(directory) / filename for filename in ("original.sqlite3", "evidence.json", "units.sqlite3"))
            with closing(sqlite3.connect(original)) as database:
                database.execute("CREATE TABLE metadata(key PRIMARY KEY,value)")
                database.executemany("INSERT INTO metadata VALUES (?,?)", [
                    ("best_source_sha256", "a" * 64), ("best_number_key_format", "preserve-separators-v1")])
                database.commit()
            evidence.write_text(json.dumps({"schema_version": 1, "source_sha256": "b" * 64, "records": []}))
            with self.assertRaises(ValueError):
                augment.augment(original, evidence, output)
            self.assertFalse(output.exists())
            self.assertFalse(augment.valid_record({"latitude": float("nan")}))

    def test_exact_osm_rows_keep_literal_codes_and_require_matching_pbf_provenance(self):
        with tempfile.TemporaryDirectory() as directory, closing(sqlite3.connect(":memory:")) as database:
            source = Path(directory) / "osm.json"
            database.executescript("CREATE TABLE addresses(street_key,number_key,postcode,latitude,longitude,osm_type,osm_id,city_key); CREATE TABLE street_aliases(street_key,alias_key,PRIMARY KEY(street_key,alias_key)); CREATE TABLE metadata(key PRIMARY KEY,value);")
            row = {"street_key": "teststraat", "number_key": "10/2", "postcode": "1000", "latitude": 50.85,
                   "longitude": 4.35, "osm_type": "osm_exact", "osm_id": 123, "city_key": "brussel"}
            data = {"schema_version": 1, "source_sha256": "a" * 64,
                    "osm_exact_number_key_format": "preserve-separators-v1", "rows": [row]}
            source.write_text(json.dumps(data))
            self.assertEqual(1, augment.import_osm(database, source, {"source_sha256": "a" * 64}))
            self.assertEqual([("10/2", "osm_exact")], database.execute("SELECT number_key,osm_type FROM addresses").fetchall())
            with self.assertRaises(ValueError):
                augment.import_osm(database, source, {"source_sha256": "b" * 64})
            self.assertEqual(1, database.execute("SELECT COUNT(*) FROM addresses").fetchone()[0])


if __name__ == "__main__":
    unittest.main()
