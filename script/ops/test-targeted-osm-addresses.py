#!/usr/bin/env python3
"""Focused tests for exact public OSM address extraction; no network use."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("targeted_osm", Path(__file__).with_name("extract-targeted-osm-addresses.py"))
osm = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = osm
spec.loader.exec_module(osm)


def target(number="10/2", names=()):
    return osm.Target("court:1", "teststraat", number, "1000", "brussel", "https://www.tribunaux-rechtbanken.be/nl/example", names)


def tags(number="10/2", **extra):
    return {"addr:street": "Teststraat", "addr:housenumber": number,
            "addr:postcode": "1000", "addr:city": "Brussel", **extra}


class ExactOsmTest(unittest.TestCase):
    def test_house_punctuation_is_preserved_and_ranges_or_units_are_not_split(self):
        collector = osm.Collector([target()])
        for index, number in enumerate(["102", "10-2", "10", "10;2", "10/2", "10 / 2"], start=1):
            collector.node(index, tags(number), 50.85, 4.35)
        self.assertEqual([5, 6], [row["source_osm_id"] for row in collector.rows])
        self.assertTrue(all(row["number_key"] == "10/2" for row in collector.rows))
        self.assertEqual("401/f", osm.number_key("401 / F"))
        self.assertNotEqual(osm.number_key("401/F"), osm.number_key("401F"))

    def test_postcode_and_street_must_be_explicit_and_exact_no_city_inference(self):
        collector = osm.Collector([target()])
        collector.node(1, tags(**{"addr:postcode": ""}), 50.85, 4.35)
        collector.node(2, tags(**{"addr:street": "Otherstraat"}), 50.85, 4.35)
        collector.node(3, tags(**{"addr:postcode": "1001"}), 50.85, 4.35)
        collector.node(4, tags(**{"addr:country": "NL"}), 50.85, 4.35)
        collector.node(5, tags(**{"addr:city": ""}), 50.85, 4.35)
        self.assertEqual(1, len(collector.rows))
        self.assertEqual("", collector.rows[0]["city_key"])
        self.assertEqual("osm_exact", collector.rows[0]["osm_type"])

    def test_all_distinct_exact_points_are_kept_for_downstream_ambiguity_checks(self):
        collector = osm.Collector([target()])
        collector.node(1, tags(), 50.85, 4.35)
        collector.node(2, tags(), 50.86, 4.36)
        self.assertEqual(2, len(collector.rows))
        self.assertNotEqual(collector.rows[0]["latitude"], collector.rows[1]["latitude"])
        self.assertNotEqual(osm.stable_id("node", 1), osm.stable_id("way", 1))

    def test_no_street_centroid_open_way_or_partial_building_geometry(self):
        collector = osm.Collector([target()])
        refs = [1, 2, 3, 4, 1]
        collector.way(1, tags(highway="residential"), refs)
        collector.way(2, tags(building="yes"), [1, 2, 3])
        collector.way(3, tags(building="yes"), refs)
        collector.finish_ways({1: (50.85, 4.35), 2: (50.85, 4.351), 3: (50.851, 4.351)})
        self.assertEqual([], collector.rows)
        self.assertEqual(3, len(collector.geometry_rejections))

    def test_building_point_is_within_actual_closed_footprint(self):
        collector = osm.Collector([target()])
        collector.way(1, tags(building="yes"), [1, 2, 3, 4, 1])
        collector.finish_ways({1: (50.85, 4.35), 2: (50.85, 4.352),
                               3: (50.852, 4.352), 4: (50.852, 4.35)})
        row = collector.rows[0]
        self.assertAlmostEqual(50.851, row["latitude"])
        self.assertAlmostEqual(4.351, row["longitude"])
        self.assertEqual("building_polygon_centroid", row["point_method"])
        self.assertEqual("10/2", row["raw_tags"]["addr:housenumber"])
        self.assertIsNone(osm.polygon_point([(50.85, 4.35)]*4))

    def test_coordinate_bounds_fail_closed(self):
        collector = osm.Collector([target()])
        for lat, lon in [(80.0, 4.35), (50.85, 80.0), (float("nan"), 4.35)]:
            collector.node(1, tags(), lat, lon)
        self.assertEqual([], collector.rows)

    def test_court_poi_requires_exact_court_name_street_and_postcode(self):
        collector = osm.Collector([target(names=("vredegerecht",))])
        for name in ["Rechtbank", "Vredegerecht West", "Vredegerecht"]:
            collector.node(1, tags("", name=name, amenity="courthouse"), 50.85, 4.35)
        collector.node(2, tags("", name="Vredegerecht", amenity="courthouse", **{"addr:postcode": "9999"}), 50.85, 4.35)
        self.assertEqual([], collector.rows)
        self.assertEqual(1, len(collector.court_pois))
        self.assertTrue(collector.court_pois[0]["review_required"])

    def test_input_schema_retains_house_codes_and_reports_unparsed_not_guessed(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/"public-targets.json"
            source.write_text(json.dumps([
                {"index": 1, "parts": {"street": "Teststraat", "number": "10 / 2", "postcode": "1000", "city": "Brussel"}},
                {"index": 2, "geocoding_address": "Teststraat 401/F, 1000 Brussel"},
                {"index": 3, "address": "Teststraat 10 bus 2, 1000 Brussel"},
                {"index": 4, "address": "Place du Palais, 1000 Bruxelles"}
            ]), encoding="utf-8")
            targets, skipped, sources = osm.load_targets([source])
            self.assertEqual(["10/2", "401/f"], [item.number_key for item in targets])
            self.assertEqual(2, len(skipped))
            self.assertEqual(64, len(sources[0]["sha256"]))
            self.assertEqual("teststraat", targets[0].street_key)

    @unittest.skipUnless(importlib.util.find_spec("osmium"), "Optional pinned osmium build dependency")
    def test_two_pass_extraction_publishes_exact_rows_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source, targets, output = base/"source.osm", base/"targets.json", base/"output.json"
            source.write_text('''<osm version="0.6">
              <node id="1" lat="50.85" lon="4.35"/>
              <node id="2" lat="50.85" lon="4.352"/>
              <node id="3" lat="50.852" lon="4.352"/>
              <node id="4" lat="50.852" lon="4.35"/>
              <node id="10" lat="50.85" lon="4.35">
                <tag k="addr:street" v="Teststraat"/><tag k="addr:housenumber" v="102"/>
                <tag k="addr:postcode" v="1000"/>
              </node>
              <way id="11"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
                <tag k="building" v="yes"/><tag k="addr:street" v="Teststraat"/>
                <tag k="addr:housenumber" v="10/2"/><tag k="addr:postcode" v="1000"/>
                <tag k="addr:city" v="Brussel"/>
              </way></osm>''', encoding="utf-8")
            targets.write_text(json.dumps([{"index": 1, "geocoding_address": "Teststraat 10/2, 1000 Brussel"}]), encoding="utf-8")
            original = source.read_bytes()
            result = osm.extract(source, output, [targets])
            self.assertEqual(1, len(result["rows"]))
            self.assertEqual("way", result["rows"][0]["source_osm_type"])
            self.assertEqual("10/2", result["rows"][0]["number_key"])
            self.assertEqual("preserve-separators-v1", result["osm_exact_number_key_format"])
            self.assertNotIn("osm_number_key_format", result)
            self.assertEqual(original, source.read_bytes())
            self.assertEqual([], result["unmatched_target_ids"])
            with self.assertRaises(ValueError):
                osm.extract(source, output, [targets])


if __name__ == "__main__":
    unittest.main()
