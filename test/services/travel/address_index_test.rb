require "test_helper"
require "tempfile"

class TravelAddressIndexTest < ActiveSupport::TestCase
  setup do
    @file = Tempfile.new([ "lawrelay-osm", ".sqlite3" ])
    @file.close
    @database = SQLite3::Database.new(@file.path)
    @database.execute("CREATE TABLE addresses (street_key, number_key, postcode, latitude, longitude, city_key, osm_type)")
    @database.execute("CREATE TABLE street_aliases (street_key, alias_key)")
    @database.execute("CREATE TABLE courts (name_key, city_key, latitude, longitude, osm_type)")
    @database.execute("CREATE TABLE metadata (key, value)")
    @database.execute("INSERT INTO metadata VALUES ('schema_version', '1')")
    @database.execute("INSERT INTO metadata VALUES ('source_sha256', ?)", [ "a" * 64 ])
    @database.execute("INSERT INTO metadata VALUES ('osm_number_key_format', 'preserve-separators-v1')")
    @database.execute("INSERT INTO street_aliases VALUES ('rueexemple', 'voorbeeldstraat')")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.85, 4.35, 'bruxelles', 'node')")
    @index = Travel::AddressIndex.new(path: @file.path)
  end

  teardown do
    @database.close
    @file.unlink
  end

  test "resolves a complete address using postcode street number and mapped language alias" do
    point = @index.address("Voorbeeldstraat 13 , 1000 Brussel")

    assert_equal 50.85, point.latitude
    assert_equal 4.35, point.longitude
    assert_equal point, @index.address("Voorbeeldstraat 13 bus 2, 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat 14, 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat 13, 2000 Antwerpen")
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Luxembourg")
    assert_nil @index.address("Brussel")
    assert_nil @index.address("x" * 501)
  end

  test "refuses ambiguous distant matches but collapses duplicate node and building points" do
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.85001, 4.35001, '', 'way')")
    assert @index.address("Voorbeeldstraat 13, 1000 Brussel")

    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.86, 4.36, '', 'way')")
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Brussel")
  end

  test "court resolution requires mapped court name and matching city including multilingual city aliases" do
    @database.execute("INSERT INTO courts VALUES ('justiceofpeacebrussels', 'bruxelles', 50.86, 4.36, 'way')")
    point = @index.court(name: "Justice of Peace Brussels", city: "Brussel")
    assert_equal 50.86, point.latitude
    assert_nil @index.court(name: "Justice of Peace Brussels", city: "Antwerpen")
    assert_nil @index.court(name: "Unmapped court", city: "Brussel")
    assert_nil @index.court(name: "Justice of Peace Brussels", city: "")
  end

  test "invalid points missing indexes and SQL input cannot manufacture a match" do
    @database.execute("UPDATE addresses SET latitude = 90")
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat' OR 1=1 -- 13, 1000 Brussel")
    assert_not Travel::AddressIndex.new(path: "").available?
    assert_nil Travel::AddressIndex.new(path: "").address("Voorbeeldstraat 13, 1000 Brussel")
  end

  test "partial empty and unsupported index metadata fail readiness closed" do
    assert @index.available?
    @database.execute("DELETE FROM metadata WHERE key = 'source_sha256'")
    assert_not @index.available?
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Brussel")
    @database.execute("INSERT INTO metadata VALUES ('source_sha256', ?)", [ "b" * 64 ])
    assert @index.available?
    @database.execute("UPDATE metadata SET value = '2' WHERE key = 'schema_version'")
    assert_not @index.available?
    @database.execute("DROP TABLE metadata")
    assert_not @index.available?
  end

  test "a unique official address wins over conflicting OSM building centres" do
    enable_best
    10.times do |number|
      @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', ?, 4.35, 'bruxelles', 'way')", [ 50.87 + number / 1000.0 ])
    end
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.86, 4.36, 'bruxelles', 'best')")
    assert_equal 50.86, @index.address("Voorbeeldstraat 13, 1000 Brussel").latitude

    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.88, 4.38, 'bruxelles', 'best')")
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Brussel")
  end

  test "house-number separators stay distinct and legacy OSM keys are not a fallback" do
    enable_best
    @database.execute("DELETE FROM metadata WHERE key = 'osm_number_key_format'")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '10/2', '1000', 50.86, 4.36, 'bruxelles', 'best')")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '102', '1000', 50.87, 4.37, 'bruxelles', 'best')")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '10-12', '1000', 50.88, 4.38, 'bruxelles', 'best')")
    assert_equal 50.86, @index.address("Voorbeeldstraat 10/2, 1000 Brussel").latitude
    assert_equal 50.86, @index.address("Voorbeeldstraat 10 / 2, 1000 Brussel").latitude
    assert_equal 50.87, @index.address("Voorbeeldstraat 102, 1000 Brussel").latitude
    assert_equal 50.88, @index.address("Voorbeeldstraat 10-12, 1000 Brussel").latitude
    assert_nil @index.address("Voorbeeldstraat 1012, 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Brussel")
    assert @index.best_available?
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13a', '1000', 50.89, 4.39, 'bruxelles', 'best')")
    assert_equal 50.89, @index.address("Voorbeeldstraat 13 A, 1000 Brussel").latitude
  end

  test "official courts take priority and known ambiguous or unmapped official addresses block old OSM points" do
    @database.execute("INSERT INTO courts VALUES ('justiceofpeacebrussels', 'bruxelles', 50.85, 4.35, 'way')")
    @database.execute("INSERT INTO courts VALUES ('justiceofpeacebrussels', 'bruxelles', 50.86, 4.36, 'official')")
    assert_equal 50.86, @index.court(name: "Justice of Peace Brussels", city: "Brussel").latitude
    @database.execute("CREATE TABLE court_sources (name_key, city_key, status)")
    @database.execute("INSERT INTO court_sources VALUES ('justiceofpeacebrussels', 'bruxelles', 'ambiguous')")
    assert_nil @index.court(name: "Justice of Peace Brussels", city: "Brussel")
    @database.execute("UPDATE court_sources SET status = 'unmapped'")
    assert_nil @index.court(name: "Justice of Peace Brussels", city: "Brussel")
  end

  test "readiness refuses an old index with no usable separator-preserving address layer" do
    @database.execute("DELETE FROM metadata WHERE key = 'osm_number_key_format'")
    assert_not @index.available?
    assert_nil @index.address("Voorbeeldstraat 13, 1000 Brussel")
    enable_best
    assert @index.available?
    @database.execute("DELETE FROM metadata WHERE key = 'best_number_key_format'")
    assert_not @index.available?
  end

  test "postal municipality aliases require the identical unique official point rather than nearby locations" do
    enable_best
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.86, 4.36, 'publishedvillage', 'best')")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple', '13', '1000', 50.86, 4.36, 'registeredmunicipality', 'best')")
    assert @index.official_city_alias?("Voorbeeldstraat 13, 1000 Published Village", city: "Registered Municipality")
    @database.execute("UPDATE addresses SET latitude = 50.86001 WHERE city_key = 'registeredmunicipality'")
    assert_not @index.official_city_alias?("Voorbeeldstraat 13, 1000 Published Village", city: "Registered Municipality")
    assert_not @index.official_city_alias?("Voorbeeldstraat 13, 1000 Published Village", city: "Missing City")
  end

  private

  def enable_best
    @database.execute("INSERT INTO metadata VALUES ('best_source_sha256', ?)", [ "b" * 64 ])
    @database.execute("INSERT INTO metadata VALUES ('best_number_key_format', 'preserve-separators-v1')")
  end
end
