require "test_helper"
require "tmpdir"
require_relative "../../../script/ops/build-court-hearing-locations"

class CourtHearingLocationsBuilderTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  SOURCE = "https://www.tribunaux-rechtbanken.be/fr/tribunal-de-premiere-instance-du-brabant-wallon".freeze
  Index = Class.new do
    def available? = true
    def official_city_alias?(_value, city:) = false
  end

  test "three hearing selectors retain their own street and primary source" do
    streets = [ "Rue de Soignies 8", "Place Albert Ier 17", "Avenue Jean Monnet 12" ]
    entries = streets.map { |street| entry.merge("hearing_address" => street) }
    result = build(entries:, record: record(streets.map { |street| "#{street}, 1400 Nivelles" }))

    assert_equal streets.map { |street| "#{street}, 1400 Nivelles" }, result.fetch(:records).map { |row| row.fetch("address") }
    assert result.fetch(:records).all? { |row| row["source_url"] == SOURCE && row["status"] == "available" }
    assert_equal "2026-11-01", result.fetch(:reviewed_on)
    assert_equal "parsed-json-v1", result.fetch(:catalogue_hash_format)
  end

  test "a shared source without a hearing selector stays ambiguous" do
    result = build(entries: [ entry ], record: record([ "Rue de Soignies 8, 1400 Nivelles", "Place Albert Ier 17, 1400 Nivelles" ]))

    assert_equal "ambiguous", result.fetch(:records).sole.fetch("status")
    assert_nil result.fetch(:records).sole["address"]
  end

  test "another town's published address is never selected" do
    result = build(entries: [ entry ], record: record([ "Place Royale 7, 1000 Bruxelles" ]))

    assert_nil result.fetch(:records).sole["address"]
  end

  test "unconfirmed venues and combined building numbers have no street result" do
    unconfirmed = build(entries: [ entry.merge("hearing_verified" => false) ], record: record([ "Rue de Soignies 8, 1400 Nivelles" ]))
    combined = build(entries: [ entry ], record: record([ "Rue de Soignies 1 et 7/1, 1400 Nivelles" ]))

    assert_equal "unconfirmed", unconfirmed.fetch(:records).sole.fetch("status")
    assert_nil unconfirmed.fetch(:records).sole["address"]
    assert_equal "ambiguous", combined.fetch(:records).sole.fetch("status")
    assert_nil combined.fetch(:records).sole["address"]
  end

  test "source identity must match before an address can be published" do
    result = build(entries: [ entry ], record: record([ "Rue de Soignies 8, 1400 Nivelles" ]).merge("source_url" => "https://example.test/unrelated"))

    assert_equal "unavailable", result.fetch(:records).sole.fetch("status")
    assert_nil result.fetch(:records).sole["address"]
  end

  test "a reviewed same-host contact query uses the importer URL rules" do
    reviewed = record([ "Rue de Soignies 8, 1400 Nivelles" ]).merge("final_url" => "#{SOURCE}/info?page=n1164")
    result = build(entries: [ entry ], record: nil, overrides: { SOURCE => reviewed })

    assert_equal "Rue de Soignies 8, 1400 Nivelles", result.fetch(:records).sole.fetch("address")
    assert_equal reviewed.fetch("final_url"), result.fetch(:records).sole.fetch("source_url")
  end

  private

  def entry
    { "source" => SOURCE, "city" => "Nivelles" }
  end

  def record(addresses)
    { "source_url" => SOURCE, "final_url" => SOURCE, "status" => "ok", "addresses" => addresses }
  end

  def build(entries:, record:, overrides: {})
    catalogue = Module.new
    catalogue.const_set(:DATA, { "courts" => entries, "places" => {} })
    Dir.mktmpdir("court-hearing-locations-test") do |directory|
      sources = File.join(directory, "sources.json")
      reviewed = File.join(directory, "reviewed.json")
      index = File.join(directory, "public-index-evidence")
      File.write(sources, JSON.generate(schema_version: 1, records: record ? { SOURCE => record } : {}))
      File.write(reviewed, JSON.generate(reviewed_on: "2026-11-01", records: overrides))
      File.write(index, "Public synthetic source evidence")
      CourtHearingLocationsBuilder.new(sources_path: sources, overrides_path: reviewed, index_path: index, catalogue:, index: Index.new).call
    end
  end
end
