#!/usr/bin/env python3
import hashlib
from contextlib import closing
import importlib.util
import io
import sqlite3
import tempfile
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

spec = importlib.util.spec_from_file_location("best_index", Path(__file__).with_name("import-best-addresses.py"))
best = importlib.util.module_from_spec(spec)
spec.loader.exec_module(best)


class Transformer:
    def transform(self, x, y):
        self.last_input = (x, y)
        return 4.35, 50.85


def wrap(tag, content):
    return f'<tns:{tag} xmlns:tns="{best.NS["tns"]}" xmlns:com="{best.NS["com"]}">{content}</tns:{tag}>'


def address(number="13", status="current", official="true", crs="3812", position="building"):
    return wrap("address", f'''
      <com:code><com:objectIdentifier>1</com:objectIdentifier></com:code>
      <com:addressStatus><com:status>{status}</com:status></com:addressStatus>
      <com:officiallyAssigned>{official}</com:officiallyAssigned><com:houseNumber>{number}</com:houseNumber>
      <com:hasStreetName><com:objectIdentifier>street</com:objectIdentifier></com:hasStreetName>
      <com:hasMunicipality><com:objectIdentifier>city</com:objectIdentifier></com:hasMunicipality>
      <com:hasPostalInfo><com:objectIdentifier>1000</com:objectIdentifier></com:hasPostalInfo>
      <com:position><com:pointGeometry><com:point><com:pos srsName="http://www.opengis.net/def/crs/EPSG/0/{crs}">650000 670000</com:pos></com:point></com:pointGeometry><com:positionSpecification>{position}</com:positionSpecification></com:position>
    ''')


class BestAddressesTest(unittest.TestCase):
    def rows(self, xml, transformer=None):
        return best.address_rows(ET.fromstring(xml), "Brussels", {"street": ("Rue du Test", "Teststraat")},
                                 {"city": ("Bruxelles", "Brussel")}, {}, {}, transformer or Transformer())

    def test_uses_current_official_exact_addresses_and_xy_coordinate_order(self):
        transformer = Transformer()
        rows = self.rows(address(), transformer)
        self.assertEqual((650000.0, 670000.0), transformer.last_input)
        self.assertEqual({"bruxelles", "brussel"}, {row[7] for row in rows})
        self.assertTrue(all(row[:6] == ("ruedutest", "13", "1000", 50.85, 4.35, "best") for row in rows))
        self.assertTrue(all(0 <= row[6] < 2**63 for row in rows))
        self.assertEqual(rows, self.rows(address()))

    def test_rejects_historic_unassigned_and_unknown_crs_without_guessing(self):
        for xml in [address(status="retired"), address(official="false"), address(crs="31370"), address(number="SN")]:
            self.assertEqual([], self.rows(xml))
        self.assertEqual([], self.rows(address().replace("1000", "unknown")))

    def test_house_number_separators_never_collide(self):
        self.assertEqual("10/2", self.rows(address(number="10/2"))[0][1])
        self.assertEqual("102", self.rows(address(number="102"))[0][1])
        self.assertEqual("10-12", self.rows(address(number="10-12"))[0][1])
        self.assertEqual("13a", self.rows(address(number="13 A"))[0][1])

    def test_coordinate_bounds_fail_closed(self):
        class Outside:
            def transform(self, *_):
                return 4.35, 80.0
        self.assertEqual([], self.rows(address(), Outside()))
        self.assertEqual([], self.rows(address().replace("650000 670000", "nan 670000")))

    def test_no_administrative_or_street_centroids_are_treated_as_a_premise(self):
        for position in ["administrativeUnit", "municipality", "addressArea", "postalDescriptor", "street", "segment", "unknown", ""]:
            self.assertEqual([], self.rows(address(position=position)))

    def test_collocated_units_keep_a_published_point_and_distinct_premises_remain_ambiguous(self):
        with closing(sqlite3.connect(":memory:")) as db:
            db.execute("CREATE TABLE addresses (street_key,number_key,postcode,latitude,longitude,osm_type,osm_id,city_key)")
            db.execute("CREATE TABLE best_import_addresses AS SELECT * FROM addresses")
            rows = [("street", "13", "1000", 50.85, 4.35, "best", 1, "city"),
                    ("street", "13", "1000", 50.85001, 4.35001, "best", 2, "city"),
                    ("street", "15", "1000", 50.85, 4.35, "best", 3, "city"),
                    ("street", "15", "1000", 50.86, 4.36, "best", 4, "city")]
            db.executemany("INSERT INTO best_import_addresses VALUES (?,?,?,?,?,?,?,?)", rows)
            self.assertEqual(3, best.publish_staged_rows(db))
            self.assertEqual([(50.85, 4.35)], db.execute("SELECT latitude,longitude FROM addresses WHERE number_key='13'").fetchall())
            self.assertEqual(2, db.execute("SELECT COUNT(*) FROM addresses WHERE number_key='15'").fetchone()[0])

    def test_complete_nested_archive_augments_only_a_new_index_with_metadata_and_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source.zip"
            original = base / "original.sqlite3"
            output = base / "output.sqlite3"
            with closing(sqlite3.connect(original)) as db, db:
                db.executescript("CREATE TABLE metadata(key PRIMARY KEY,value); CREATE TABLE addresses(street_key,number_key,postcode,latitude,longitude,osm_type,osm_id,city_key); CREATE TABLE street_aliases(street_key,alias_key,PRIMARY KEY(street_key,alias_key));")
                db.executemany("INSERT INTO metadata VALUES (?,?)", [("schema_version", "1"), ("source_sha256", "0" * 64)])
                db.execute("INSERT INTO addresses VALUES ('oldstreet','1','1000',50.85,4.35,'node',1,'brussel')")
            before = hashlib.sha256(original.read_bytes()).hexdigest()
            with zipfile.ZipFile(source, "w") as outer:
                for region in best.REGIONS:
                    fixtures = {
                        "Municipality": wrap("municipality", '<com:code><com:objectIdentifier>city</com:objectIdentifier></com:code><com:name><com:spelling>Brussel</com:spelling></com:name>'),
                        "StreetName": wrap("streetName", '<com:code><com:objectIdentifier>street</com:objectIdentifier></com:code><com:name><com:spelling>Rue du Test</com:spelling></com:name><com:name><com:spelling>Teststraat</com:spelling></com:name>'),
                        "PostalInfo": wrap("postalInfo", '<com:code><com:objectIdentifier>1000</com:objectIdentifier></com:code><com:name><com:spelling>Bruxelles/Brussel</com:spelling></com:name>'), "Address": address(),
                    }
                    for kind, content in fixtures.items():
                        nested = io.BytesIO()
                        with zipfile.ZipFile(nested, "w") as inner:
                            inner.writestr(f"{region}{kind}20261101.xml", wrap("response", content))
                        outer.writestr(f"{region}{kind}20261101.zip", nested.getvalue())
            best.build(source, original, output, transformer=Transformer())
            self.assertEqual(before, hashlib.sha256(original.read_bytes()).hexdigest())
            with closing(sqlite3.connect(output)) as db:
                self.assertEqual(1, db.execute("SELECT COUNT(*) FROM addresses WHERE osm_type='node'").fetchone()[0])
                self.assertGreater(db.execute("SELECT COUNT(*) FROM addresses WHERE osm_type='best'").fetchone()[0], 0)
                self.assertIn(("ruedutest", "teststraat"), db.execute("SELECT * FROM street_aliases").fetchall())
                self.assertEqual("CC-BY-4.0", db.execute("SELECT value FROM metadata WHERE key='best_license'").fetchone()[0])
                self.assertEqual("preserve-separators-v1", db.execute("SELECT value FROM metadata WHERE key='best_number_key_format'").fetchone()[0])
                self.assertEqual("1", db.execute("SELECT value FROM metadata WHERE key='best_postal_aliases_expanded'").fetchone()[0])
                self.assertIn(("bruxelles",), db.execute("SELECT city_key FROM addresses WHERE osm_type='best'").fetchall())
            self.assertFalse(base.joinpath("output.building.sqlite3").exists())
            with self.assertRaises(ValueError):
                best.build(source, original, output, transformer=Transformer())


if __name__ == "__main__":
    unittest.main()
