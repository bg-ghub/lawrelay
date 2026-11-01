require "test_helper"
require_relative "../support/marketplace_test_factory"

class LawyerProfilePreferencesTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  setup { @profile = create_marketplace_account(prefix: "preference-bounds").profile }

  test "each matching preference has a count and individual length bound" do
    LawyerProfile::PREFERENCE_LIMITS.each do |attribute, limits|
      @profile.reload
      @profile[attribute] = (1..limits[:count]).map { |i| "choice-#{i}" }
      assert @profile.valid?, @profile.errors.full_messages.join(", ")

      @profile[attribute] << "one-extra-choice"
      assert_not @profile.valid?
      assert @profile.errors.of_kind?(attribute, :too_many_preferences)

      @profile[attribute] = [ "X" * (limits[:length] + 1) ]
      assert_not @profile.valid?
      assert @profile.errors.of_kind?(attribute, :preference_too_long)
    end
  end

  test "comma-separated values cannot bypass count limits" do
    @profile.practice_areas = [ (1..51).map { |i| "area-#{i}" }.join(",") ]
    assert_not @profile.valid?
    assert @profile.errors.of_kind?(:practice_areas, :too_many_preferences)
  end

  test "malformed preference values are rejected without exceptions" do
    [ [ { "unexpected" => "object" } ], [ [ "nested" ] ], [ 123 ], "not an array" ].each do |value|
      @profile.reload
      @profile.court_preferences = value
      assert_not @profile.valid?
      assert @profile.errors.of_kind?(:court_preferences, :invalid)
    end
  end

  test "reasonable custom and multilingual choices remain available" do
    @profile.spoken_languages = [ "NL, FR", "Español" ]
    @profile.practice_areas = [ " Custom legal area ", "Custom legal area" ]
    @profile.court_preferences = [ "Custom court, Brussels" ]
    assert @profile.save
    assert_equal [ "NL", "FR", "Español" ], @profile.reload.spoken_languages
    assert_equal [ "Custom legal area" ], @profile.practice_areas
    assert_equal [ "Custom court", "Brussels" ], @profile.court_preferences
  end
end
