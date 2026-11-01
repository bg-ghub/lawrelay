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

  test "slash unit notation requires an explicit official house and box relationship" do
    enable_best_units
    @database.execute("INSERT INTO best_units VALUES ('rueexemple','11','201','1000',50.86,4.36,'bruxelles')")
    point = @index.address("Voorbeeldstraat 11/201, 1000 Brussel")
    assert_equal 50.86, point.latitude
    assert_nil @index.address("Voorbeeldstraat 11/202, 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat 11201, 1000 Brussel")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','11/201','1000',50.88,4.38,'bruxelles','best')")
    assert_equal 50.88, @index.address("Voorbeeldstraat 11/201, 1000 Brussel").latitude
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','11/201','1000',50.89,4.39,'bruxelles','best')")
    assert_nil @index.address("Voorbeeldstraat 11/201, 1000 Brussel")
  end

  test "unit points remain ambiguous and evidence from a different BeSt source is ignored" do
    enable_best_units
    @database.execute("INSERT INTO best_units VALUES ('rueexemple','11','201','1000',50.86,4.36,'bruxelles')")
    @database.execute("INSERT INTO best_units VALUES ('rueexemple','11','201','1000',50.89,4.39,'bruxelles')")
    assert_nil @index.address("Voorbeeldstraat 11/201, 1000 Brussel")
    @database.execute("DELETE FROM best_units WHERE latitude=50.89")
    @database.execute("UPDATE metadata SET value=? WHERE key='best_unit_source_sha256'", [ "c" * 64 ])
    assert_nil @index.address("Voorbeeldstraat 11/201, 1000 Brussel")
  end

  test "explicit floor and box formatting does not change the house number" do
    assert @index.address("Voorbeeldstraat 13 (3ème étage), 1000 Brussel")
    assert @index.address("Voorbeeldstraat 13 - 5de verdieping, 1000 Brussel")
    assert @index.address("Voorbeeldstraat n°13, 1000 Brussel")
    assert @index.address("Voorbeeldstraat 13 b19, 1000 Brussel")
    assert @index.address("Voorbeeldstraat 13/bus 19, 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat 13 (annex building), 1000 Brussel")
    assert_nil @index.address("Voorbeeldstraat 13 - 15, 1000 Brussel")
  end

  test "numeric box padding is normalized only within proven units and conflicting units stay ambiguous" do
    enable_best_units
    @database.execute("INSERT INTO best_units VALUES ('rueexemple','11','0201','1000',50.86,4.36,'bruxelles')")
    assert_equal 50.86, @index.address("Voorbeeldstraat 11/201, 1000 Brussel").latitude
    assert_nil @index.address("Voorbeeldstraat 11201, 1000 Brussel")
    @database.execute("INSERT INTO best_units VALUES ('rueexemple','11','201','1000',50.89,4.39,'bruxelles')")
    assert_nil @index.address("Voorbeeldstraat 11/201, 1000 Brussel")
  end

  test "only separator-preserving exact OSM evidence can fill an absent official address" do
    enable_best
    @database.execute("DELETE FROM metadata WHERE key = 'osm_number_key_format'")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','11/2','1000',50.86,4.36,'bruxelles','osm_exact')")
    assert_nil @index.address("Voorbeeldstraat 11/2, 1000 Brussel")
    @database.execute("INSERT INTO metadata VALUES ('osm_exact_number_key_format','preserve-separators-v1')")
    @database.execute("INSERT INTO metadata VALUES ('osm_exact_source_sha256', ?)", [ "a" * 64 ])
    assert_equal 50.86, @index.address("Voorbeeldstraat 11/2, 1000 Brussel").latitude
    assert_nil @index.address("Voorbeeldstraat 112, 1000 Brussel")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','11/2','1000',50.88,4.38,'bruxelles','best')")
    assert_equal 50.88, @index.address("Voorbeeldstraat 11/2, 1000 Brussel").latitude
  end

  test "a qualified venue keeps its own translations while shared legacy names stay ambiguous" do
    @database.execute("INSERT INTO courts VALUES ('courtbrusselsvenuea','bruxelles',50.85,4.35,'official')")
    @database.execute("INSERT INTO courts VALUES ('tribunalbruxellessitea','bruxelles',50.85,4.35,'official')")
    @database.execute("INSERT INTO courts VALUES ('courtbrusselsvenueb','bruxelles',50.87,4.37,'official')")
    @database.execute("INSERT INTO courts VALUES ('legacycourtbrussels','bruxelles',50.85,4.35,'official')")
    @database.execute("INSERT INTO courts VALUES ('legacycourtbrussels','bruxelles',50.87,4.37,'official')")
    options = [
      { current_labels: [ "Court Brussels venue A", "Tribunal Bruxelles site A" ], labels: [ "Court Brussels venue A", "Legacy court Brussels" ], cities: [ "Bruxelles" ] },
      { current_labels: [ "Court Brussels venue B" ], labels: [ "Court Brussels venue B", "Legacy court Brussels" ], cities: [ "Bruxelles" ] }
    ]
    with_court_options(options) do
      assert_equal 50.85, @index.court(name: "Court Brussels venue A", city: "Brussel").latitude
      assert_equal 50.87, @index.court(name: "Court Brussels venue B", city: "Brussel").latitude
      assert_nil @index.court(name: "Legacy court Brussels", city: "Brussel")
    end
  end

  test "an explicitly unconfirmed catalogue venue cannot use an old mapped point" do
    @database.execute("INSERT INTO courts VALUES ('unconfirmedcourt','bruxelles',50.85,4.35,'way')")
    options = [ { current_labels: [ "Unconfirmed court" ], labels: [ "Unconfirmed court" ], cities: [ "Bruxelles" ], hearing_verified: false } ]
    with_court_options(options) do
      assert_nil @index.court(name: "Unconfirmed court", city: "Brussel")
    end
  end

  test "a global alias from another locality cannot shadow the exact official street" do
    enable_best
    @database.execute("INSERT INTO street_aliases VALUES ('kazernestraat','kazernestraat')")
    @database.execute("INSERT INTO street_aliases VALUES ('minderbroedersstraat','kazernestraat')")
    @database.execute("INSERT INTO addresses VALUES ('kazernestraat','4','9100',51.17,4.13,'sintniklaas','best')")
    @database.execute("INSERT INTO addresses VALUES ('minderbroedersstraat','4','9100',51.18,4.15,'sintniklaas','best')")
    @database.execute("INSERT INTO addresses VALUES ('minderbroedersstraat','6','9100',51.18,4.15,'sintniklaas','best')")
    assert_equal 51.17, @index.address("Kazernestraat 4, 9100 Sint-Niklaas").latitude
    assert_nil @index.address("Kazernestraat 6, 9100 Sint-Niklaas")
    @database.execute("INSERT INTO addresses VALUES ('kazernestraat','4','9100',51.19,4.17,'sintniklaas','best')")
    assert_nil @index.address("Kazernestraat 4, 9100 Sint-Niklaas")
  end

  test "a literal official name in another postcode does not disable a local bilingual alias" do
    enable_best
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','13','1000',50.86,4.36,'bruxelles','best')")
    @database.execute("INSERT INTO addresses VALUES ('voorbeeldstraat','13','2000',51.22,4.4,'antwerpen','best')")
    assert_equal 50.86, @index.address("Voorbeeldstraat 13, 1000 Brussel").latitude
  end

  test "an absent literal range requires both unique collocated official endpoints and never interpolates" do
    enable_best
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','10','1000',50.86,4.36,'bruxelles','best')")
    assert_nil @index.address("Voorbeeldstraat 10-12, 1000 Brussel")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','12','1000',50.86005,4.36005,'bruxelles','best')")
    assert_equal({ latitude: 50.86, longitude: 4.36 }, @index.address("Voorbeeldstraat 10-12, 1000 Brussel").to_h)
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','10-12','1000',50.87,4.37,'bruxelles','best')")
    assert_equal 50.87, @index.address("Voorbeeldstraat 10-12, 1000 Brussel").latitude
    @database.execute("DELETE FROM addresses WHERE number_key='10-12'")
    @database.execute("UPDATE addresses SET latitude=50.88 WHERE number_key='12'")
    assert_nil @index.address("Voorbeeldstraat 10-12, 1000 Brussel")
    @database.execute("UPDATE addresses SET latitude=50.86005 WHERE number_key='12'")
    @database.execute("INSERT INTO addresses VALUES ('rueexemple','12','1000',50.89,4.39,'bruxelles','best')")
    assert_nil @index.address("Voorbeeldstraat 10-12, 1000 Brussel")
  end

  private

  def enable_best
    @database.execute("INSERT INTO metadata VALUES ('best_source_sha256', ?)", [ "b" * 64 ])
    @database.execute("INSERT INTO metadata VALUES ('best_number_key_format', 'preserve-separators-v1')")
  end

  def enable_best_units
    enable_best
    @database.execute("INSERT INTO metadata VALUES ('best_unit_source_sha256', ?)", [ "b" * 64 ])
    @database.execute("CREATE TABLE best_units (street_key,number_key,box_key,postcode,latitude,longitude,city_key)")
  end

  def with_court_options(options)
    original = CourtCatalogue.method(:options)
    CourtCatalogue.define_singleton_method(:options) { |**| options }
    yield
  ensure
    CourtCatalogue.define_singleton_method(:options, original)
  end
end
