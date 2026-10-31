require "test_helper"

class CourtCatalogueTest < ActiveSupport::TestCase
  test "catalogue covers all official ordinary court types and their listed venues" do
    data = JSON.parse(Rails.root.join("config/courts.be.json").read)
    courts = data.fetch("courts")

    assert_equal %w[appeal assize cassation constitutional enterprise first_instance labour labour_appeal peace police state], courts.map { |court| court.fetch("type") }.uniq.sort
    assert_equal 163, courts.count { |court| court.fetch("type") == "peace" }
    assert_equal 320, courts.size
    assert_equal courts.size, courts.map { |court| court.fetch("source") }.uniq.size
    assert courts.all? { |court| court.fetch("source").start_with?("https://") }
    assert_equal "2026-10-31", data.fetch("checked_on")
    assert_equal 9, data.fetch("overview_sources").size
  end

  test "court names and cities fit existing assignment fields in every language" do
    %i[nl fr de en].each do |locale|
      options = CourtCatalogue.options(locale:)

      assert_equal 320, options.size
      assert options.all? { |option| option.fetch(:label).length <= 180 }
      assert options.all? { |option| option.fetch(:city).present? && option.fetch(:city).length <= 100 }
      refute_match(/translation missing/i, options.map { |option| option.fetch(:label) }.join(" "))
    end
  end

  test "divisions language-specific Brussels courts and seats remain distinguishable" do
    options = CourtCatalogue.options(locale: :nl)
    assert options.any? { |court| court[:label] == "Ondernemingsrechtbank Antwerpen — afdeling Mechelen" && court[:city] == "Mechelen" }
    assert options.any? { |court| court[:label] == "Politierechtbank Brussel (Nederlandstalig)" && court[:city] == "Brussel" }
    assert options.any? { |court| court[:label] == "Politierechtbank Brussel (Franstalig)" && court[:city] == "Brussel" }
    assert options.any? { |court| court[:label] == "Hof van assisen Vlaams-Brabant — Leuven" && court[:city] == "Leuven" }
    assert options.any? { |court| court[:label] == "Rechtbank van eerste aanleg Waals-Brabant — Nivelles" && court[:city] == "Nivelles" }
    assert options.any? { |court| court[:label].include?("Philippeville - siège Couvin") && court[:city] == "Couvin" }
  end

  test "multilingual search includes original places and first instance sections" do
    options = CourtCatalogue.options(locale: :en)
    court = options.find { |option| option[:label] == "Court of first instance Liège — division Liège" }

    assert_not_nil court
    %w[Luik Liège Lüttich family familierechtbank correctionnel jeunesse].each do |word|
      assert_includes court.fetch(:search), word
    end
    assert_equal "Liège", court.fetch(:city)
  end
end
