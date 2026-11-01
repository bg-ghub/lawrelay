require "application_system_test_case"

class GeoChallengeSystemTest < ApplicationSystemTestCase
  setup do
    @original_enabled = GeoCountry.method(:challenge_enabled?)
    @original_country = GeoCountry.method(:country_for)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    GeoCountry.define_singleton_method(:challenge_enabled?) { true }
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
  end

  teardown do
    Capybara.reset_sessions!
    GeoCountry.define_singleton_method(:challenge_enabled?, @original_enabled)
    GeoCountry.define_singleton_method(:country_for, @original_country)
    Rails.cache = @original_cache
  end

  test "the local proof solves automatically and returns to the public page under CSP" do
    visit root_path(locale: :en)

    assert_current_path geo_challenge_path(locale: :en)
    assert_selector "altcha-widget"

    assert_current_path root_path(locale: :en), wait: 20
    assert_selector "main h1"
  end

  test "the challenge page has translated copy in every public locale" do
    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    # Keep this rendering check on the challenge page. Automatic proof and
    # redirect are exercised without interception in the separate happy path.
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*altcha-challenge.json*" ])

    %i[nl fr de en].each do |locale|
      visit geo_challenge_path(locale:)

      assert_current_path geo_challenge_path(locale:)
      assert_selector "html[lang='#{locale}']"
      assert_selector "altcha-widget"
      assert_text I18n.t("geo_challenge.heading", locale:)
      assert_no_text "Translation missing"
    end
  ensure
    if browser
      browser.execute_cdp("Network.setBlockedURLs", urls: [])
      browser.execute_cdp("Network.disable")
    end
  end
end
