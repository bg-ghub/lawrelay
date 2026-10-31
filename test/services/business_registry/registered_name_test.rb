require "minitest/autorun"
require_relative "../../../app/services/business_registry/registered_name"

class BusinessRegistryRegisteredNameTest < Minitest::Test
  def test_prefixes_the_registered_form_using_the_official_abbreviation
    {
      "Besloten Vennootschap" => "BV",
      "Naamloze vennootschap" => "NV",
      "Coöperatieve vennootschap" => "CV",
      "Vennootschap onder firma" => "VOF",
      "Commanditaire vennootschap" => "CommV",
      "Vereniging zonder winstoogmerk" => "VZW",
      "Internationale vereniging zonder winstoogmerk" => "IVZW",
      "Europese vennootschap" => "SE",
      "Europese coöperatieve vennootschap" => "SCE",
      "Europees economisch samenwerkingsverband" => "EESV",
      "Stichting van openbaar nut" => "SON",
      "Private stichting" => "PS"
    }.each do |form, abbreviation|
      assert_equal "#{abbreviation} BG Legal", format_name("BG Legal", form:), form
    end
  end

  def test_keeps_legacy_forms_distinct_from_current_forms
    {
      "Besloten vennootschap met beperkte aansprakelijkheid" => "BVBA",
      "Besloten vennootschap met beperkte aansprakelijkheid (met inbegrip van eenpersoonsvennootschap)" => "BVBA",
      "Besloten vennootschap met beperkte aansprakelijkheid starter" => "S-BVBA",
      "Coöperatieve vennootschap met beperkte aansprakelijkheid" => "CVBA",
      "Coöperatieve vennootschap met onbeperkte aansprakelijkheid" => "CVOA",
      "Gewone commanditaire vennootschap" => "Comm.V",
      "Commanditaire vennootschap op aandelen" => "Comm. VA",
      "Economisch samenwerkingsverband" => "ESV",
      "Landbouwvennootschap" => "LV"
    }.each do |form, abbreviation|
      assert_equal "#{abbreviation} BG Legal", format_name("BG Legal", form:), form
    end
  end

  def test_normalizes_existing_prefixes_and_suffixes_without_duplicate_forms
    [
      "BV BG Legal", "B.V. BG Legal", "b.v. BG Legal", "(BV) BG Legal",
      "BG Legal BV", "BG Legal B.V.", "BG Legal, BV", "BG Legal (B.V.)",
      "BG Legal [BV]", "BG Legal - BV", "Besloten vennootschap BG Legal",
      "BG Legal (Besloten Vennootschap)", "BV BG Legal BV"
    ].each do |name|
      assert_equal "BV BG Legal", format_name(name), name
    end
    assert_equal "CommV BG Legal", format_name("BG Legal Comm. V", form: "Commanditaire vennootschap")
    assert_equal "BV", format_name("B.V.")
  end

  def test_does_not_strip_words_that_only_contain_the_legal_form_abbreviation
    assert_equal "BV BVG Legal", format_name("BVG Legal")
    assert_equal "BV LegalBV", format_name("LegalBV")
    assert_equal "BV BG Legal BVBA", format_name("BG Legal BVBA")
    assert_equal "BVBA BG Legal", format_name("BG Legal B.V.B.A.", form: "Besloten vennootschap met beperkte aansprakelijkheid")
    assert_equal "BVBA BG Legal S-BVBA", format_name("BG Legal S-BVBA", form: "Besloten vennootschap met beperkte aansprakelijkheid")
    assert_equal "BVBA SPRL-S BG Legal", format_name("SPRL-S BG Legal", form: "Besloten vennootschap met beperkte aansprakelijkheid")
    assert_equal "S-BVBA BG Legal", format_name("BG Legal S-BVBA", form: "Besloten vennootschap met beperkte aansprakelijkheid starter")
    assert_equal "S-BVBA BG Legal", format_name("SPRL-S BG Legal", form: "Besloten vennootschap met beperkte aansprakelijkheid starter")
  end

  def test_normalizes_equivalent_french_and_german_abbreviations_only_for_the_registered_form
    [ "SRL BG Legal", "BG Legal S.R.L.", "BG Legal GmbH" ].each do |name|
      assert_equal "BV BG Legal", format_name(name), name
    end
    assert_equal "NV BG Legal", format_name("BG Legal S.A.", form: "Naamloze vennootschap")
    assert_equal "CV BG Legal", format_name("BG Legal GEN.", form: "Coöperatieve vennootschap")
    assert_equal "VOF BG Legal", format_name("BG Legal SNC", form: "Vennootschap onder firma")
    assert_equal "CommV BG Legal", format_name("BG Legal SComm", form: "Commanditaire vennootschap")
    assert_equal "VZW BG Legal", format_name("BG Legal ASBL", form: "Vereniging zonder winstoogmerk")
    assert_equal "IVZW BG Legal", format_name("BG Legal IVOG", form: "Internationale vereniging zonder winstoogmerk")
    assert_equal "BVBA BG Legal", format_name("BG Legal SPRL", form: "Besloten vennootschap met beperkte aansprakelijkheid")
    assert_equal "BV BG Legal SPRL", format_name("BG Legal SPRL")
    assert_equal "BVBA BG Legal SRL", format_name("BG Legal SRL", form: "Besloten vennootschap met beperkte aansprakelijkheid")
  end

  def test_never_infers_a_form_for_missing_or_unknown_registry_values
    assert_equal "Jan Janssens", format_name("Jan Janssens", form: nil)
    assert_equal "Jan Janssens", format_name("Jan Janssens", form: "Eenmanszaak")
    assert_equal "BG Legal", format_name("BG Legal", form: "Onbekende rechtsvorm")
    assert_equal "Jan Janssens", format_name("Jan Janssens", form: nil, type: nil)
    assert_equal "Jan Janssens", format_name("Jan Janssens", form: nil, type: "Onbekend")
    assert_equal "", format_name(nil)
  end

  def test_uses_the_NP_display_designation_only_for_an_explicit_natural_person_type
    assert_equal "NP Gauthier Berth", format_name("Gauthier Berth", form: nil, type: "Natuurlijk persoon")
    assert_equal "NP Jan Janssens", format_name("Jan Janssens", type: "Natuurlijke persoon")
    assert_equal "NP Gauthier Berth", format_name("NP Gauthier Berth", form: nil, type: "Natuurlijk persoon")
    assert_equal "NP Gauthier Berth", format_name("Gauthier Berth (N.P.)", form: nil, type: "Natuurlijk persoon")
  end

  private

  def format_name(name, form: "Besloten vennootschap", type: "Rechtspersoon")
    BusinessRegistry::RegisteredName.call(name:, legal_form: form, entity_type: type)
  end
end
