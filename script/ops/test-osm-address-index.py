#!/usr/bin/env python3
import importlib.util
import sqlite3
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("osm_index", Path(__file__).with_name("build-osm-address-index.py"))
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)


class IndexTest(unittest.TestCase):
    def setUp(self):
        self.database = sqlite3.connect(":memory:")
        index.create_schema(self.database)
        self.writer = index.Writer(self.database, {"Brussel": {"fr": "Bruxelles", "en": "Brussels"}})

    def tearDown(self):
        self.database.close()

    def test_keeps_only_precise_addresses_and_known_court_features(self):
        self.writer.add({"addr:street": "Example Street", "addr:housenumber": "13", "addr:postcode": "1000", "name": "Private office"}, 50.85, 4.35, "node", 1)
        self.writer.add({"name": "Unrelated café", "addr:city": "Brussel"}, 50.85, 4.35, "node", 2)
        self.writer.add({"amenity": "courthouse", "name": "Vredegerecht", "addr:city": "Brussel"}, 50.86, 4.36, "node", 3)
        self.assertEqual(1, self.database.execute("SELECT COUNT(*) FROM addresses").fetchone()[0])
        self.assertEqual(0, self.database.execute("SELECT COUNT(*) FROM courts WHERE name LIKE '%café%'").fetchone()[0])
        self.assertEqual(1, self.database.execute("SELECT COUNT(*) FROM courts WHERE name_key = 'vredegerechtbrussel' AND city_key = 'brussel'").fetchone()[0])

    def test_rejects_invalid_postcodes_ambiguous_numbers_and_outside_country(self):
        tags = {"addr:street": "Example Street", "addr:housenumber": "13", "addr:postcode": "1000"}
        self.writer.add(tags, 52.0, 4.35, "node", 1)
        self.writer.add(tags | {"addr:postcode": ""}, 50.85, 4.35, "node", 2)
        self.writer.add(tags | {"addr:housenumber": "13;15"}, 50.85, 4.35, "node", 3)
        self.assertEqual(0, self.database.execute("SELECT COUNT(*) FROM addresses").fetchone()[0])

    def test_multilingual_street_aliases_link_same_mapped_street(self):
        self.writer.add({"highway": "residential", "name": "Zavelstraat - Rue du Sable", "name:nl": "Zavelstraat", "name:fr": "Rue du Sable"}, 50.85, 4.35, "way", 1)
        aliases = self.database.execute("SELECT alias_key FROM street_aliases WHERE street_key = 'zavelstraat'").fetchall()
        self.assertIn(("ruedusable",), aliases)

    def test_normalization_matches_diacritics_without_addresses_in_metadata(self):
        self.assertEqual("ruedeloeuvre13", index.normalize("Rue de l’Œuvre, 13"))
        self.assertEqual([], self.database.execute("SELECT * FROM metadata").fetchall())

    def test_house_number_separators_do_not_collide(self):
        tags = {"addr:street": "Example Street", "addr:postcode": "1000"}
        for identifier, number in enumerate(("10/2", "102", "10-12", "1012"), start=1):
            self.writer.add(tags | {"addr:housenumber": number}, 50.85, 4.35, "node", identifier)
        self.assertEqual([("10/2",), ("102",), ("10-12",), ("1012",)],
                         self.database.execute("SELECT number_key FROM addresses ORDER BY osm_id").fetchall())


if __name__ == "__main__":
    unittest.main()
