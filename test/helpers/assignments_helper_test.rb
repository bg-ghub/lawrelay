require "test_helper"

class AssignmentsHelperTest < ActionView::TestCase
  tests AssignmentsHelper
  self.fixture_table_names = []

  test "reviewed public address notes follow the interface language without changing street names" do
    notes = {
      nl: [ "1e verdieping", "3e verdieping", "Gebouw van de FOD Financiën" ],
      fr: [ "1er étage", "3e étage", "Bâtiment du SPF Finances" ],
      de: [ "1. Stock", "3. Stock", "Gebäude des FÖD Finanzen" ],
      en: [ "1st floor", "3rd floor", "FPS Finance building" ]
    }
    notes.each do |locale, (first_floor, third_floor, finance_building)|
      I18n.with_locale(locale) do
        {
          "justice-de-paix-de-ciney" => "Rue Courtejoie 17 (#{third_floor}), 5590 Ciney",
          "justice-de-paix-de-braine-lalleud" => "Rue Pierre Flamand 64 (#{first_floor}), 1420 Braine-l'Alleud",
          "justice-de-paix-de-mouscron" => "Place Lamartine 1 (#{finance_building}), 7700 Mouscron",
          "vredegerecht-oudenaarde" => "Beverstraat 7B (#{first_floor}), 9700 Oudenaarde"
        }.each do |slug, expected|
          entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("source").end_with?("/#{slug}") }
          option = CourtCatalogue.option_for(entry, locale:)
          assignment = Assignment.new(court: option.fetch(:label), city: option.fetch(:city))
          published_address = CourtHearingLocations.find(name: assignment.court, city: assignment.city).address.dup

          assert_equal expected, assignment_hearing_details(assignment).fetch(:location)
          assert_equal published_address, CourtHearingLocations.find(name: assignment.court, city: assignment.city).address
        end
      end
    end
  end

  test "unknown annotations and street text remain unchanged" do
    I18n.with_locale(:nl) do
      address = "Rue du 3ème étage 17 (entrée côté cour), 5590 Ciney"
      assert_equal address, send(:localized_court_address_notes, address)
    end
  end

  test "custom locations bypass canonical address note localization" do
    I18n.with_locale(:nl) do
      assignment = Assignment.new(court: "Synthetic custom court", city: "Custom Street 1 (3ème étage)")
      details = assignment_hearing_details(assignment)

      assert_equal "Synthetic custom court", details.fetch(:court)
      assert_equal "Custom Street 1 (3ème étage)", details.fetch(:location)
      assert_equal false, details.fetch(:address_unavailable)
    end
  end
end
