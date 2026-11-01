require "test_helper"

class CourtCatalogueTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "catalogue covers all official ordinary court types and their listed venues" do
    data = JSON.parse(Rails.root.join("config/courts.be.json").read)
    courts = data.fetch("courts")

    assert_equal %w[appeal assize cassation constitutional enterprise first_instance labour labour_appeal peace police state], courts.map { |court| court.fetch("type") }.uniq.sort
    assert_equal 163, courts.count { |court| court.fetch("type") == "peace" }
    assert_equal 325, courts.size
    assert_equal 320, courts.map { |court| court.fetch("source") }.uniq.size
    assert_equal courts.size, courts.map { |court| court.values_at("source", "city", "hearing_address") }.uniq.size
    assert courts.all? { |court| court.fetch("source").start_with?("https://") }
    assert_equal "2026-11-01", data.fetch("checked_on")
    assert_equal 9, data.fetch("overview_sources").size
  end

  test "court names and cities fit existing assignment fields in every language" do
    %i[nl fr de en].each do |locale|
      options = CourtCatalogue.options(locale:)

      assert_equal 325, options.size
      assert_equal options.size, options.map { |option| option.fetch(:label) }.uniq.size
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
    assert options.any? { |court| court[:labels].include?("Rechtbank van eerste aanleg Waals-Brabant — Nivelles") && court[:city] == "Nivelles" }
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

  test "national institutions use their names without a Brussels suffix and retain old labels" do
    %w[cassation constitutional state].each do |type|
      entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("type") == type }
      CourtCatalogue::LOCALES.each do |locale|
        name = I18n.t("court_picker.types.#{type}", locale:)
        city = CourtCatalogue::DATA.fetch("places").dig("Brussel", locale.to_s) || "Brussel"
        option = CourtCatalogue.option_for(entry, locale:)

        assert_equal name, option.fetch(:label)
        assert_equal name, CourtCatalogue.court_name(entry, locale:)
        assert_includes option.fetch(:cities), city
        assert_includes option.fetch(:current_labels), name
        assert_includes option.fetch(:labels), "#{name} #{city}"
        refute_includes option.fetch(:current_labels), "#{name} #{city}"
      end
    end
  end

  test "Brussels assize court spells out its administrative jurisdiction in every language" do
    entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("type") == "assize" && court.fetch("district") == "Brussel" }
    expected = {
      nl: "Hof van assisen van het administratief arrondissement Brussel-Hoofdstad",
      fr: "Cour d’assises de l’arrondissement administratif de Bruxelles-Capitale",
      de: "Assisenhof des Verwaltungsbezirks Brüssel-Hauptstadt",
      en: "Assize court of the administrative district of Brussels-Capital"
    }
    expected.each do |locale, name|
      option = CourtCatalogue.option_for(entry, locale:)
      city = CourtCatalogue::DATA.fetch("places").dig("Brussel", locale.to_s) || "Brussel"
      legacy = "#{I18n.t('court_picker.types.assize', locale:)} #{city}"

      assert_equal name, option.fetch(:label)
      assert_equal name, CourtCatalogue.court_name(entry, locale:)
      assert_includes option.fetch(:labels), legacy
      assert_includes option.fetch(:current_labels), name
      refute_includes option.fetch(:current_labels), legacy
    end
  end

  test "reviewed relocated courts display and fill their actual hearing town while retaining legacy aliases" do
    expected = {
      "vredegerecht-oudergem" => [ "Oudergem", "Etterbeek" ],
      "justice-de-paix-de-limbourg" => [ "Limbourg", "Eupen" ],
      "justice-de-paix-de-vise" => [ "Visé", "Cheratte" ],
      "vredegerecht-geraardsbergen" => [ "Geraardsbergen", "Brakel" ],
      "politierechtbank-limburg-afdeling-genk" => [ "Genk", "Tongeren-Borgloon" ],
      "arbeidsrechtbank-gent-afdeling-roeselare" => [ "Roeselare", "Kortrijk" ]
    }
    expected.each do |slug, (judicial_city, hearing_city)|
      entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("source").end_with?("/#{slug}") }
      assert_equal judicial_city, entry.fetch("judicial_city")
      assert_equal hearing_city, entry.fetch("city")

      CourtCatalogue::LOCALES.each do |locale|
        option = CourtCatalogue.option_for(entry, locale:)
        actual_city = CourtCatalogue::DATA.fetch("places").dig(hearing_city, locale.to_s) || hearing_city
        original_city = CourtCatalogue::DATA.fetch("places").dig(judicial_city, locale.to_s) || judicial_city
        assert_equal actual_city, option.fetch(:city)
        assert_includes option.fetch(:label), I18n.t("court_picker.hearing_place", locale:, place: actual_city)
        assert_includes option.fetch(:cities), actual_city
        assert_includes option.fetch(:cities), original_city
        qualification = " — #{I18n.t('court_picker.hearing_place', locale:, place: actual_city)}"
        assert_includes option.fetch(:labels), option.fetch(:label).delete_suffix(qualification)
        assert_includes option.fetch(:current_labels), option.fetch(:label)
        refute_includes option.fetch(:current_labels), option.fetch(:label).delete_suffix(qualification)
        assert_includes CourtCatalogue.options(locale:), option
      end
    end
  end

  test "courts with multiple hearing places preserve shared historical labels without choosing a place" do
    expected = {
      "Binche" => %w[Charleroi] + [ "La Louvière" ],
      "Mouscron" => %w[Tournai Mons Charleroi]
    }
    expected.each do |division, hearing_cities|
      entries = CourtCatalogue::DATA.fetch("courts").select { |court| court["type"] == "labour" && court["venue"] == division }
      assert_equal hearing_cities.sort, entries.map { |entry| entry.fetch("city") }.sort
      assert_equal 1, entries.map { |entry| entry.fetch("source") }.uniq.size

      CourtCatalogue::LOCALES.each do |locale|
        options = entries.map { |entry| CourtCatalogue.option_for(entry, locale:) }
        shared_labels = options.map { |option| option.fetch(:labels) }.reduce(:&)
        assert shared_labels.any? { |label| label.end_with?("#{I18n.t('court_picker.division', locale:)} #{division}") }
        assert_equal options.size, options.map { |option| option.fetch(:label) }.uniq.size
        options.each do |option|
          assert_includes option.fetch(:cities), division
          assert_includes option.fetch(:label), option.fetch(:city)
          assert shared_labels.all? { |label| option.fetch(:labels).include?(label) }
          assert_empty option.fetch(:current_labels) & shared_labels
        end
        shared_labels.each do |label|
          matches = CourtCatalogue.options(locale:).select { |option| option.fetch(:labels).include?(label) && option.fetch(:cities).include?(division) }
          assert_equal options.size, matches.size, "Historical #{division} labels must remain ambiguous"
        end
      end
    end
  end

  test "unconfirmed Saint Vith police hearings remain explicit and do not invent a destination" do
    entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("source").end_with?("/tribunal-de-police-deupen-division-saint-vith") }
    assert_equal "Saint-Vith", entry.fetch("city")
    assert_equal false, entry.fetch("hearing_verified")
    assert_nil entry["hearing_place"]

    CourtCatalogue::LOCALES.each do |locale|
      option = CourtCatalogue.option_for(entry, locale:)
      assert_equal false, option.fetch(:hearing_verified)
      assert_includes option.fetch(:label), I18n.t("court_picker.hearing_unconfirmed", locale:)
      qualification = " — #{I18n.t('court_picker.hearing_unconfirmed', locale:)}"
      assert_includes option.fetch(:labels), option.fetch(:label).delete_suffix(qualification)
    end
  end

  test "same town hearing choices can distinguish their street without sharing current labels" do
    base = CourtCatalogue::DATA.fetch("courts").find { |court| court["type"] == "first_instance" && court["city"] == "Nivelles" }
    first = CourtCatalogue.option_for(base.merge("hearing_place" => "Nivelles", "hearing_address" => "Example Street 1"), locale: :en)
    second = CourtCatalogue.option_for(base.merge("hearing_place" => "Nivelles", "hearing_address" => "Example Street 2"), locale: :en)

    assert_equal first.fetch(:city), second.fetch(:city)
    assert_includes first.fetch(:label), "Example Street 1"
    assert_includes second.fetch(:label), "Example Street 2"
    assert_empty first.fetch(:current_labels) & second.fetch(:current_labels)
    assert_not_empty first.fetch(:labels) & second.fetch(:labels)
  end

  test "Nivelles first instance sections retain their three confirmed hearing buildings" do
    entries = CourtCatalogue::DATA.fetch("courts").select { |court| court.fetch("source").end_with?("/tribunal-de-premiere-instance-du-brabant-wallon") }
    assert_equal 3, entries.size
    assert_equal({
      "civil_and_family" => "Rue de Soignies 8",
      "criminal" => "Place Albert Ier 17",
      "youth_protection" => "Avenue Jean Monnet 12"
    }, entries.to_h { |entry| entry.values_at("hearing_subject", "hearing_address") })
    assert entries.all? { |entry| entry.fetch("city") == "Nivelles" && entry.fetch("hearing_place") == "Nivelles" }

    CourtCatalogue::LOCALES.each do |locale|
      options = entries.map { |entry| CourtCatalogue.option_for(entry, locale:) }
      entries.zip(options).each do |entry, option|
        assert_includes option.fetch(:label), entry.fetch("hearing_address")
        assert_includes option.fetch(:label), I18n.t("court_picker.hearing_subjects.#{entry.fetch('hearing_subject')}", locale:)
      end
      assert_equal 3, options.map { |option| option.fetch(:label) }.uniq.size
      options.combination(2) { |first, second| assert_empty first.fetch(:current_labels) & second.fetch(:current_labels) }
      shared_labels = options.map { |option| option.fetch(:labels) }.reduce(:&)
      assert_not_empty shared_labels
      shared_labels.each do |label|
        assert_equal 3, CourtCatalogue.options(locale:).count { |option| option.fetch(:labels).include?(label) && option.fetch(:cities).include?("Nivelles") }
      end
    end
  end
end
