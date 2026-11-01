require "test_helper"
require "tmpdir"
require_relative "../../../script/ops/import-court-addresses"

class CourtAddressImporterTest < ActiveSupport::TestCase
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

  private

  def importer
    CourtAddressImporter.new(input_path: @input, output_path: @output, sources_path: @sources, catalogue: Catalogue)
  end
end
