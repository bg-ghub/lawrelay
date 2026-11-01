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

    def test_a_way_requires_a_complete_closed_building_and_uses_an_interior_point(self):
        tags = {"building": "yes", "addr:street": "Example Street", "addr:housenumber": "13", "addr:postcode": "1000"}
        square = [(50.85,4.35),(50.85,4.3502),(50.8502,4.3502),(50.8502,4.35),(50.85,4.35)]
        self.writer.add(tags, 50.85, 4.35, "way", 1)
        self.writer.add(tags, 50.85, 4.35, "way", 2, footprint=square[:-1])
        self.writer.add(tags | {"building": "no"}, 50.85, 4.35, "way", 3, footprint=square)
        self.writer.add(tags | {"highway": "service"}, 50.85, 4.35, "way", 4, footprint=square)
        self.assertEqual(0, self.database.execute("SELECT COUNT(*) FROM addresses").fetchone()[0])
        self.writer.add(tags, 50.85, 4.35, "way", 5, footprint=square)
        latitude, longitude = self.database.execute("SELECT latitude,longitude FROM addresses").fetchone()
        self.assertTrue(50.85 < latitude < 50.8502)
        self.assertTrue(4.35 < longitude < 4.3502)

    def test_concave_self_crossing_degenerate_and_outside_buildings_are_rejected(self):
        tags = {"building": "yes"}
        shapes = [
            [(50.85,4.35),(50.85,4.3504),(50.8501,4.3501),(50.8504,4.35),(50.85,4.35)],
            [(50.85,4.35),(50.8504,4.3504),(50.85,4.3504),(50.8504,4.35),(50.85,4.35)],
            [(50.85,4.35),(50.85,4.3501),(50.85,4.3502),(50.85,4.35)],
            [(50.85,4.35),(50.85,4.3501),(90,4.3501),(50.85,4.35)],
        ]
        for shape in shapes:
            self.assertIsNone(index.building_point(tags, shape))

    def test_a_road_address_node_cannot_become_a_premise(self):
        self.writer.add({"highway": "traffic_signals", "addr:street": "Example Street", "addr:housenumber": "13",
                         "addr:postcode": "1000"}, 50.85, 4.35, "node", 1)
        self.assertEqual(0, self.database.execute("SELECT COUNT(*) FROM addresses").fetchone()[0])


if __name__ == "__main__":
    unittest.main()
