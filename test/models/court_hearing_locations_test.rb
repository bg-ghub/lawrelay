require "test_helper"

class CourtHearingLocationsTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "published address data is bound to this catalogue and public sources" do
    assert CourtHearingLocations.available?
    data = CourtHearingLocations::DATA
    assert_equal 326, data.fetch("records").length
    assert_equal 326, data.fetch("records").count { |row| row["status"] == "available" }
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, data.fetch("reviewed_on"))
    %w[official_sources_sha256 reviewed_overrides_sha256 official_address_index_sha256].each do |key|
      assert_match(/\A[0-9a-f]{64}\z/, data.fetch(key))
    end
    data.fetch("records").select { |row| row["status"] == "available" }.each do |row|
      assert row.fetch("source_url").start_with?("https://")
      assert_match(/\d{4}\s+/, row.fetch("address"))
      refute_includes row.fetch("address"), "@"
    end
  end

  test "each Nivelles hearing selects its own full address in every language" do
    expected = { "Rue de Soignies 8" => "Rue de Soignies 8, 1400 Nivelles",
      "Place Albert Ier 17" => "Place Albert Ier 17, 1400 Nivelles",
      "Avenue Jean Monnet 12" => "Avenue Jean Monnet 12, 1400 Nivelles" }
    CourtCatalogue::LOCALES.each do |locale|
      expected.each do |street, address|
        option = CourtCatalogue.options(locale:).find { |value| value.fetch(:label).include?(street) }
        result = CourtHearingLocations.find(name: option.fetch(:label), city: option.fetch(:city), locale:)

        assert_equal address, result.address
        refute_includes result.court_name, street
        refute_includes result.court_name, I18n.t("court_picker.hearing_place", locale:, place: "Nivelles")
      end
    end
  end

  test "all current catalogue choices resolve consistently across interface languages" do
    CourtCatalogue::LOCALES.each do |locale|
      details = CourtCatalogue.options(locale:).map do |option|
        CourtHearingLocations.find(name: option.fetch(:label), city: option.fetch(:city), locale:)
      end

      assert_equal 326, details.compact.length
      assert_equal 326, details.count { |result| result&.address.present? }
    end
  end

  test "display addresses remain available without a routing engine or address index" do
    original_index, original_router = ENV.values_at("LAWRELAY_OSM_INDEX_PATH", "LAWRELAY_OSRM_URL")
    ENV["LAWRELAY_OSM_INDEX_PATH"] = "/missing/local-routing-index.sqlite3"
    ENV.delete("LAWRELAY_OSRM_URL")

    details = CourtHearingLocations.find(name: "Justice of the peace Aalst 1", city: "Aalst", locale: :en)
    assert_equal "Dr. André Sierensstraat 16, 9300 Aalst", details.address
    assert_equal "Justice of the peace Aalst 1", details.court_name
  ensure
    ENV["LAWRELAY_OSM_INDEX_PATH"] = original_index
    ENV["LAWRELAY_OSRM_URL"] = original_router
  end

  test "a stored label can be displayed in the chosen interface language" do
    option = CourtCatalogue.options(locale: :nl).find { |value| value.fetch(:label).include?("Rue de Soignies 8") }
    details = CourtHearingLocations.find(name: option.fetch(:label), city: "Nivelles", locale: :en)

    assert_equal "Court of first instance Walloon Brabant — Nivelles", details.court_name
    assert_equal "Rue de Soignies 8, 1400 Nivelles", details.address
  end

  test "a unique historical singleton label upgrades to the official name and full address" do
    { "Court of Cassation Brussels" => :en, "Hof van Cassatie Brussel" => :nl }.each do |legacy, locale|
      details = CourtHearingLocations.find(name: legacy, city: "Brussels", locale:)

      assert_equal I18n.t("court_picker.types.cassation", locale:), details.court_name
      assert_equal "Poelaertplein 1, 1000 Brussel", details.address
    end
  end

  test "ambiguous legacy names and wrong towns never select a hearing address" do
    assert_nil CourtHearingLocations.find(name: "Court of first instance Walloon Brabant — Nivelles", city: "Nivelles", locale: :en)
    assert_nil CourtHearingLocations.find(name: "Justice of the peace Aalst 1", city: "Brussels", locale: :en)
    assert_nil CourtHearingLocations.find(name: "Synthetic notary office", city: "Brussels", locale: :en)
    assert_nil CourtHearingLocations.find(name: "A" * 181, city: "Aalst", locale: :en)
  end

  test "Saint Vith uses its published Eupen hearing address" do
    entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("source").end_with?("tribunal-de-police-deupen-division-saint-vith") }
    option = CourtCatalogue.option_for(entry, locale: :en)
    result = CourtHearingLocations.find(name: option.fetch(:label), city: option.fetch(:city), locale: :en)

    assert_equal "Rathausplatz 4, 4700 Eupen", result.address
    assert_includes result.court_name, "Saint-Vith"
    assert_includes result.court_name, "Eupen"
  end

  test "Neufchateau qualified buildings retain their own addresses and legacy name stays ambiguous" do
    entries = CourtCatalogue::DATA.fetch("courts").select do |court|
      court.fetch("source").end_with?("tribunal-de-premiere-instance-du-luxembourg-division-neufchateau")
    end
    expected = {
      "Place Charles Bergh 1" => "Place Charles Bergh 1, 6840 Neufchâteau",
      "Place Charles Bergh 7/1" => "Place Charles Bergh 7/1, 6840 Neufchâteau"
    }
    entries.each do |entry|
      option = CourtCatalogue.option_for(entry, locale: :en)
      result = CourtHearingLocations.find(name: option.fetch(:label), city: option.fetch(:city), locale: :en)
      assert_equal expected.fetch(entry.fetch("hearing_address")), result.address
    end
    assert_nil CourtHearingLocations.find(name: "Court of first instance Luxembourg — division Neufchâteau", city: "Neufchâteau", locale: :en)
  end

  test "stale address data falls back without hiding the institution name" do
    original = CourtHearingLocations.method(:available?)
    CourtHearingLocations.define_singleton_method(:available?) { false }
    result = CourtHearingLocations.find(name: "Justice of the peace Aalst 1", city: "Aalst", locale: :en)
    assert_equal "Justice of the peace Aalst 1", result.court_name
    assert_nil result.address
  ensure
    CourtHearingLocations.define_singleton_method(:available?, original) if original
  end
end
