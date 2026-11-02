require "test_helper"
require "tmpdir"
require_relative "../../../script/ops/import-court-addresses"

class CourtAddressImporterTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  class Catalogue
    LOCALES = %i[nl fr de en].freeze
    DATA = {
      "places" => { "Brussel" => { "fr" => "Bruxelles", "en" => "Brussels", "de" => "Brüssel" } },
      "courts" => %w[one two three].map { |suffix| { "city" => "Brussel", "id" => suffix, "source" => "https://www.tribunaux-rechtbanken.be/nl/fixture-#{suffix}" } }
    }.freeze
    def self.label(entry, locale)
      "#{locale} Test court #{entry.fetch('id')}"
    end
  end

  class HearingCatalogue < Catalogue
    def self.option_for(entry, locale:)
      { labels: [ label(entry, locale), "Legacy #{entry.fetch('id')}" ],
        cities: [ "Brussel", "Old Judicial City" ], hearing_verified: entry.fetch("id") != "two" }
    end
  end

  class SectionCatalogue < Catalogue
    DATA = Catalogue::DATA.merge("courts" => Catalogue::DATA.fetch("courts").map do |entry|
      entry.fetch("id") == "two" ? entry.merge("hearing_address" => "Example Street 13") : entry
    end).freeze
  end

  class MultiVenueCatalogue < Catalogue
    DATA = Catalogue::DATA.merge("courts" => Catalogue::DATA.fetch("courts") + [
      Catalogue::DATA.fetch("courts").last.merge("id" => "antwerp", "city" => "Antwerpen")
    ]).freeze
  end

  class PublishedCoordinateCatalogue < Catalogue
    DATA = {
      "places" => {},
      "courts" => [ { "city" => "Ciney", "id" => "ciney", "source" => "https://www.tribunaux-rechtbanken.be/fr/justice-de-paix-de-ciney" } ]
    }.freeze
  end

  class MultiPublishedCoordinateCatalogue < Catalogue
    DATA = PublishedCoordinateCatalogue::DATA.merge("courts" => PublishedCoordinateCatalogue::DATA.fetch("courts") + [
      PublishedCoordinateCatalogue::DATA.fetch("courts").first.merge("id" => "antwerp", "city" => "Antwerpen")
    ]).freeze
  end

  setup do
    @directory = Dir.mktmpdir("lawrelay-court-import", Rails.root.join("tmp"))
    @input = File.join(@directory, "input.sqlite3")
    @output = File.join(@directory, "completed.sqlite3")
    @sources = File.join(@directory, "official.json")
    FileUtils.cp(Rails.root.join("test/fixtures/files/court-addresses.json"), @sources)
    SQLite3::Database.new(@input) do |database|
      database.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
      { "schema_version" => "1", "source_sha256" => "a" * 64, "best_source_sha256" => "b" * 64,
        "best_number_key_format" => "preserve-separators-v1" }.each do |key, value|
        database.execute("INSERT INTO metadata VALUES (?, ?)", [ key, value ])
      end
      database.execute("CREATE TABLE addresses (street_key, number_key, postcode, latitude, longitude, osm_type, osm_id, city_key)")
      database.execute("CREATE TABLE street_aliases (street_key, alias_key)")
      database.execute("CREATE TABLE courts (name_key, city_key, latitude, longitude, osm_type, osm_id, name)")
      database.execute("INSERT INTO addresses VALUES ('examplestreet', '13', '1000', 50.86, 4.36, 'best', 1, 'brussel')")
      database.execute("INSERT INTO street_aliases VALUES ('examplestreet', 'examplestreet')")
      database.execute("INSERT INTO courts VALUES ('nltestcourtone', 'brussel', 50.85, 4.35, 'way', 2, 'Old OSM court')")
      database.execute("INSERT INTO courts VALUES ('nltestcourttwo', 'brussel', 50.85, 4.35, 'way', 3, 'Ambiguous old OSM court')")
      database.execute("INSERT INTO courts VALUES ('nltestcourtthree', 'brussel', 50.85, 4.35, 'way', 4, 'Unmapped old OSM court')")
    end
  end

  teardown do
    root = File.realpath(Rails.root.join("tmp"))
    target = File.realpath(@directory)
    raise "Unexpected test cleanup path" unless target.start_with?("#{root}/") && File.basename(target).start_with?("lawrelay-court-import")

    FileUtils.remove_entry(target)
  end

  test "imports all four official labels and city variants into a fresh copy with source hashes" do
    original_hash = Digest::SHA256.file(@input).hexdigest
    result = importer.call
    assert_equal 3, result[:court_entries]
    assert_equal({ "matched" => 1, "ambiguous" => 1, "unmapped" => 1 }, result[:counts])
    assert_equal original_hash, Digest::SHA256.file(@input).hexdigest
    index = Travel::AddressIndex.new(path: @output)
    %w[nl fr de en].each do |locale|
      point = index.court(name: "#{locale} Test court one", city: "Bruxelles")
      assert_not_nil point, "Missing localized official court #{locale}"
      assert_equal 50.86, point.latitude
    end
    assert_nil index.court(name: "nl Test court two", city: "Brussel")
    assert_nil index.court(name: "nl Test court three", city: "Brussel")
    SQLite3::Database.new(@output, readonly: true) do |database|
      assert_equal Digest::SHA256.file(@sources).hexdigest,
        database.get_first_value("SELECT value FROM metadata WHERE key = 'official_court_sources_sha256'")
      assert database.execute("SELECT source_sha256 FROM court_sources").flatten.all? { |value| value.match?(/\A[0-9a-f]{64}\z/) }
      assert_equal 16, database.get_first_value("SELECT COUNT(*) FROM courts WHERE osm_type = 'official'")
    end
  end

  test "a spoofed source or unsafe final destination cannot contribute coordinates or restore OSM fallback" do
    collection = JSON.parse(File.read(@sources))
    collection["records"].values.first["final_url"] = "https://evil.example/address"
    File.write(@sources, JSON.generate(collection))
    result = importer.call
    assert_equal 1, result[:counts]["invalid"]
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court one", city: "Brussel")
  end

  test "even a claimed ok record with multiple addresses stays ambiguous" do
    collection = JSON.parse(File.read(@sources))
    first = collection["records"].values.first
    first["addresses"] << "Other Street 2 1000 Brussel"
    File.write(@sources, JSON.generate(collection))
    result = importer.call
    assert_equal 2, result[:counts]["ambiguous"]
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court one", city: "Brussel")
  end

  test "existing output and identical input-output paths are refused" do
    File.write(@output, "keep")
    assert_raises(ArgumentError) { importer.call }
    assert_equal "keep", File.read(@output)
    assert_raises(ArgumentError) do
      CourtAddressImporter.new(input_path: @input, output_path: @input, sources_path: @sources, catalogue: Catalogue).call
    end
  end

  test "a versioned reviewed override replaces an ambiguous record and records its checksum" do
    source = Catalogue::DATA.fetch("courts")[1].fetch("source")
    override_path = File.join(@directory, "reviewed.json")
    File.write(override_path, JSON.generate({ reviewed_on: "2026-11-01", records: {
      source => { source_url: source, final_url: source, status: "ok", addresses: [ "Example Street 13 1000 Brussel" ], address_role: "hearing" }
    } }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: override_path).call
    assert_equal 2, result[:counts]["matched"]
    assert_equal Digest::SHA256.file(override_path).hexdigest, result[:overrides_sha256]
    assert_equal 50.86, Travel::AddressIndex.new(path: @output).court(name: "nl Test court two", city: "Brussel").latitude
    SQLite3::Database.new(@output, readonly: true) do |database|
      assert_equal "2026-11-01", database.get_first_value("SELECT value FROM metadata WHERE key = 'official_court_overrides_reviewed_on'")
    end
  end

  test "different-city published addresses can resolve the unique explicit venue while same-city alternatives remain blocked" do
    collection = JSON.parse(File.read(@sources))
    record = collection["records"].values[1]
    record["addresses"] = [ "Other Street 2 2000 Antwerpen", "Example Street 13 1000 Bruxelles" ]
    File.write(@sources, JSON.generate(collection))
    result = importer.call
    assert_equal 2, result[:counts]["matched"]
    assert_equal 50.86, Travel::AddressIndex.new(path: @output).court(name: "nl Test court two", city: "Brussel").latitude
  end

  test "a central registry address in another venue never becomes the hearing destination" do
    collection = JSON.parse(File.read(@sources))
    collection["records"].values.first["addresses"] = [ "Example Street 13 2000 Antwerpen" ]
    File.write(@sources, JSON.generate(collection))
    result = importer.call
    assert_equal 1, result[:counts]["venue_mismatch"]
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court one", city: "Brussel")
  end

  test "a published postal name is accepted only through the same official municipality address point" do
    SQLite3::Database.new(@input) do |database|
      database.execute("INSERT INTO addresses VALUES ('examplestreet', '13', '1000', 50.86, 4.36, 'best', 5, 'publishedvillage')")
    end
    collection = JSON.parse(File.read(@sources))
    collection["records"].values.first["addresses"] = [ "Example Street 13 1000 Published Village" ]
    File.write(@sources, JSON.generate(collection))
    assert_equal 1, importer.call[:counts]["matched"]
    assert_equal 50.86, Travel::AddressIndex.new(path: @output).court(name: "nl Test court one", city: "Brussel").latitude
  end

  test "a clearly stated parenthetical municipality can identify the venue without guessing a point" do
    collection = JSON.parse(File.read(@sources))
    collection["records"].values.first["addresses"] = [ "Example Street 13 1000 Published Village (Brussel)" ]
    File.write(@sources, JSON.generate(collection))
    assert_equal 1, importer.call[:counts]["matched"]
    assert_equal 50.86, Travel::AddressIndex.new(path: @output).court(name: "nl Test court one", city: "Brussel").latitude
  end

  test "qualified catalogue aliases are imported while unconfirmed hearing venues remain blocked" do
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: HearingCatalogue, overrides_path: nil).call
    assert_equal 1, result[:counts]["unconfirmed"]
    index = Travel::AddressIndex.new(path: @output)
    assert_equal 50.86, index.court(name: "Legacy one", city: "Old Judicial City").latitude
    assert_nil index.court(name: "Legacy two", city: "Old Judicial City")
    SQLite3::Database.new(@output, readonly: true) do |database|
      assert_equal [ "unconfirmed" ], database.execute("SELECT DISTINCT status FROM court_sources WHERE name_key='legacytwo'").flatten
    end
  end

  test "a qualified section selects its exact premise from multiple hearing addresses in the same city" do
    collection = JSON.parse(File.read(@sources))
    collection["records"].values[1]["addresses"] = [ "Other Street 9 1000 Brussel", "Example Street 13 1000 Brussel" ]
    File.write(@sources, JSON.generate(collection))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: SectionCatalogue, overrides_path: nil).call
    assert_equal 2, result[:counts]["matched"]
    assert_equal 50.86, Travel::AddressIndex.new(path: @output).court(name: "nl Test court two", city: "Brussel").latitude
  end

  test "a reviewed public courthouse point requires a versioned override and matching PBF provenance" do
    source = Catalogue::DATA.fetch("courts")[2].fetch("source")
    path = File.join(@directory, "point.json")
    record = { source_url: source, final_url: source, status: "ok", addresses: [ "Example Square 1000 Brussel" ],
      reviewed_point: { latitude: 50.87, longitude: 4.37, osm_type: "way", osm_id: 123, pbf_sha256: "a" * 64 } }
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: path).call
    assert_equal 2, result[:counts]["matched"]
    assert_equal 50.87, Travel::AddressIndex.new(path: @output).court(name: "nl Test court three", city: "Brussel").latitude
  end

  test "an unreviewed or wrong-source public point cannot manufacture a court destination" do
    collection = JSON.parse(File.read(@sources))
    record = collection["records"].values[2]
    record["reviewed_point"] = { latitude: 50.87, longitude: 4.37, osm_type: "way", osm_id: 123, pbf_sha256: "a" * 64 }
    File.write(@sources, JSON.generate(collection))
    assert_equal 1, importer.call[:counts]["invalid"]
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court three", city: "Brussel")
    FileUtils.rm(@output)
    source = record.fetch("source_url")
    record["reviewed_point"][:pbf_sha256] = "b" * 64
    path = File.join(@directory, "point.json")
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: path).call
    assert_equal 1, result[:counts]["invalid"]
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court three", city: "Brussel")
  end

  test "a reviewed municipal destination is allowed only on the curated HTTPS host" do
    source = Catalogue::DATA.fetch("courts").first.fetch("source")
    path = File.join(@directory, "municipal.json")
    record = { source_url: source, final_url: "https://www.st.vith.be/directory?key=public-court", status: "ok",
      addresses: [ "Example Street 13 1000 Brussel" ] }
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: path).call
    assert_equal 1, result[:counts]["matched"]
    FileUtils.rm(@output)
    record[:final_url] = "https://www.st.vith.be.evil.example/directory?key=public-court"
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: path).call
    assert_equal 1, result[:counts]["invalid"]
  end

  test "reviewed points are bound to the exact selected address of a multi-site source" do
    source = Catalogue::DATA.fetch("courts").last.fetch("source")
    path = File.join(@directory, "multi-site.json")
    record = { source_url: source, final_url: source, status: "ok",
      addresses: [ "Unmapped Street 777 1000 Brussel", "Other Street 9, 2000 Antwerpen" ],
      reviewed_points: [ { address: "Other Street 9, 2000 Antwerpen", latitude: 51.22, longitude: 4.4,
        osm_type: "way", osm_id: 123, pbf_sha256: "a" * 64 } ] }
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: MultiVenueCatalogue, overrides_path: path).call
    assert_equal 2, result[:counts]["matched"]
    assert_equal 1, result[:counts]["unmapped"]
    index = Travel::AddressIndex.new(path: @output)
    assert_nil index.court(name: "nl Test court three", city: "Brussel")
    assert_equal 51.22, index.court(name: "nl Test court antwerp", city: "Antwerpen").latitude
    FileUtils.rm(@output)
    record[:reviewed_points].first[:address] = "Other Street 9 2000 Antwerpen"
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: MultiVenueCatalogue, overrides_path: path).call
    assert_equal 2, result[:counts]["invalid"]
  end

  test "a single reviewed point is refused on a multi-address source" do
    source = Catalogue::DATA.fetch("courts").last.fetch("source")
    path = File.join(@directory, "multi-site.json")
    record = { source_url: source, final_url: source, status: "ok",
      addresses: [ "Unmapped Street 777 1000 Brussel", "Other Street 9 2000 Antwerpen" ],
      reviewed_point: { latitude: 51.22, longitude: 4.4, osm_type: "way", osm_id: 123, pbf_sha256: "a" * 64 } }
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: MultiVenueCatalogue, overrides_path: path).call
    assert_equal 2, result[:counts]["invalid"]
  end

  test "a reviewed relation requires complete multipolygon interior provenance" do
    source = Catalogue::DATA.fetch("courts").last.fetch("source")
    path = File.join(@directory, "relation.json")
    record = { source_url: source, final_url: source, status: "ok", addresses: [ "Example Square 1000 Brussel" ],
      reviewed_point: { latitude: 50.87, longitude: 4.37, osm_type: "relation", osm_id: 123, pbf_sha256: "a" * 64 } }
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: path).call
    assert_equal 1, result[:counts]["invalid"]
    FileUtils.rm(@output)
    record[:reviewed_point].merge!(geometry_complete: true, geometry_valid: true, point_in_building_geometry: true,
      geometry_method: "multipolygon_interior_point", geometry_sha256: "c" * 64)
    File.write(path, JSON.generate(reviewed_on: "2026-11-01", records: { source => record }))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: Catalogue, overrides_path: path).call
    assert_equal 2, result[:counts]["matched"]
  end

  test "a reviewed municipal published coordinate keeps its exact address and coordinate provenance" do
    record = official_published_record
    assert_equal({ "matched" => 1 }, import_official_published_record(record)[:counts])
    point = Travel::AddressIndex.new(path: @output).court(name: "nl Test court ciney", city: "Ciney")
    assert_equal 50.2950177, point.latitude
    assert_equal 5.100674, point.longitude
    first_hash = nil
    SQLite3::Database.new(@output, readonly: true) do |database|
      first_hash = database.get_first_value("SELECT source_sha256 FROM court_sources LIMIT 1")
    end

    FileUtils.rm(@output)
    record["reviewed_point"]["coordinate_source_sha256"] = "d" * 64
    import_official_published_record(record)
    second_hash = nil
    SQLite3::Database.new(@output, readonly: true) do |database|
      second_hash = database.get_first_value("SELECT source_sha256 FROM court_sources LIMIT 1")
    end
    assert_not_equal first_hash, second_hash, "The court source hash must retain coordinate-source provenance"
  end

  test "an unreviewed municipal published coordinate cannot create a court destination" do
    record = official_published_record
    collection = JSON.parse(File.read(@sources))
    collection["records"][record.fetch("source_url")] = record
    File.write(@sources, JSON.generate(collection))
    result = CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue: PublishedCoordinateCatalogue, overrides_path: nil).call
    assert_equal({ "invalid" => 1 }, result[:counts])
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court ciney", city: "Ciney")
  end

  test "municipal published coordinates require exact address binding a source checksum and evidence" do
    invalid_changes = [
      { "address" => "Rue Courtejoie 17 5590 Ciney" },
      { "address" => nil },
      { "coordinate_source_sha256" => "not-a-sha256" },
      { "coordinate_source_sha256" => nil },
      { "coordinate_source_url" => nil },
      { "latitude" => "50.2950177" },
      { "latitude" => 48.0 }
    ]
    invalid_changes.each do |change|
      record = official_published_record
      record.fetch("reviewed_point").merge!(change)
      result = import_official_published_record(record)
      assert_equal({ "invalid" => 1 }, result[:counts], change.inspect)
      assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court ciney", city: "Ciney")
      FileUtils.rm(@output)
    end
    record = official_published_record
    record.delete("evidence_urls")
    assert_equal({ "invalid" => 1 }, import_official_published_record(record)[:counts])
    assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court ciney", city: "Ciney")
  end

  test "municipal published coordinates accept only the curated safe HTTPS origin" do
    [
      "http://www.ciney.be/annuaire/justice-de-paix",
      "https://www.ciney.be.evil.example/annuaire/justice-de-paix",
      "https://www.ciney.be@evil.example/annuaire/justice-de-paix",
      "https://user@www.ciney.be/annuaire/justice-de-paix",
      "https://www.ciney.be:8443/annuaire/justice-de-paix",
      "https://www.ciney.be/annuaire/justice-de-paix#unverified",
      "not a URL"
    ].each do |url|
      record = official_published_record
      record.fetch("reviewed_point")["coordinate_source_url"] = url
      record["evidence_urls"] = [ url ]
      assert_equal({ "invalid" => 1 }, import_official_published_record(record)[:counts], url)
      assert_nil Travel::AddressIndex.new(path: @output).court(name: "nl Test court ciney", city: "Ciney")
      FileUtils.rm(@output)
    end
  end

  test "a municipal published point cannot apply to every address of a multi-site source" do
    record = official_published_record
    record.fetch("addresses") << "Other Street 9, 2000 Antwerpen"
    assert_equal({ "invalid" => 2 }, import_official_published_record(record, catalogue: MultiPublishedCoordinateCatalogue)[:counts])
    FileUtils.rm(@output)

    record["reviewed_points"] = [ record.delete("reviewed_point") ]
    result = import_official_published_record(record, catalogue: MultiPublishedCoordinateCatalogue)
    assert_equal({ "matched" => 1, "unmapped" => 1 }, result[:counts])
    index = Travel::AddressIndex.new(path: @output)
    assert_equal 50.2950177, index.court(name: "nl Test court ciney", city: "Ciney").latitude
    assert_nil index.court(name: "nl Test court antwerp", city: "Antwerpen")
    FileUtils.rm(@output)

    record.fetch("reviewed_points").first["address"] = "Rue Courtejoie 17 (3ème étage) 5590 Ciney"
    assert_equal({ "invalid" => 2 }, import_official_published_record(record, catalogue: MultiPublishedCoordinateCatalogue)[:counts])
  end

  private

  def official_published_record
    source = PublishedCoordinateCatalogue::DATA.fetch("courts").first.fetch("source")
    address = "Rue Courtejoie 17 ( 3ème étage ) 5590 Ciney"
    coordinate_source = "https://www.ciney.be/annuaire/justice-de-paix"
    { "source_url" => source, "final_url" => source, "status" => "ok", "addresses" => [ address ],
      "evidence_urls" => [ source, coordinate_source ],
      "reviewed_point" => { "kind" => "official_published_point", "address" => address,
        "latitude" => 50.2950177, "longitude" => 5.100674, "coordinate_source_url" => coordinate_source,
        "coordinate_source_sha256" => "d15d36a7275b3fe1e72bb55eb2980fc7f4904532a03494f47f85e0fdf9656a5d" } }
  end

  def import_official_published_record(record, catalogue: PublishedCoordinateCatalogue)
    path = File.join(@directory, "official-published-point.json")
    File.write(path, JSON.generate(reviewed_on: "2026-11-02", records: { record.fetch("source_url") => record }))
    CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources,
      catalogue:, overrides_path: path).call
  end

  def importer
    CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources, catalogue: Catalogue)
  end
end
