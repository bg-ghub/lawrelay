require "test_helper"
require_relative "../support/marketplace_test_factory"

class BetaProductFocusTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @previous_mode = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = "beta"
  end

  teardown do
    @previous_mode.nil? ? ENV.delete("LAWRELAY_RELEASE_MODE") : ENV["LAWRELAY_RELEASE_MODE"] = @previous_mode
  end

  test "public beta pages focus on the product without pricing offers in every locale" do
    I18n.available_locales.each do |locale|
      [ root_path(locale: locale), new_registration_path(locale: locale), terms_path(locale: locale),
        privacy_path(locale: locale), legal_notice_path(locale: locale), cookies_path(locale: locale) ].each do |path|
        get path

        assert_response :success
        assert_select "a[href$='/pricing'], a[href$='/billing']", count: 0
        text = Nokogiri::HTML(response.body).at_css("body").text
        assert_no_match(/€\s*\d|\b(?:subscription|subscriptions|abonnement(?:en|s)?|future income|inkomsten|revenus|Einnahmen)\b/i, text)
      end

      get root_path(locale: locale)
      assert_select ".product-bar a", count: 2
      assert_select ".footer-project__source[href='https://github.com/bg-ghub/lawrelay']"
      assert_select ".footer-project__version", text: /#{Regexp.escape(LawRelay::VERSION)}/
    end
  end

  test "beta member pages hide platform billing while keeping assignment remuneration" do
    owner = create_marketplace_account(prefix: "betafocusowner")
    assignment = create_assignment_for(owner)
    sign_in_as(owner.user)

    I18n.available_locales.each do |locale|
      get dashboard_path(locale: locale)
      assert_response :success
      assert_select "a[href$='/billing'], a[href$='/pricing']", count: 0

      get settings_path(locale: locale)
      assert_response :success
      assert_select "input[name='firm[billing_email]']", count: 0

      get new_assignment_path(locale: locale)
      assert_response :success
      assert_select "input[name='assignment[fee_cents]']"

      get assignment_path(assignment, locale: locale)
      assert_response :success
      assert_select ".proposal-panel__price strong", text: /250/
    end
  end

  test "the sitemap omits archived pricing during beta and includes it only in paid mode" do
    get "/sitemap.xml"
    assert_response :success
    assert_not_includes response.body, "/pricing"

    ENV["LAWRELAY_RELEASE_MODE"] = "paid"
    get "/sitemap.xml"
    assert_response :success
    assert_includes response.body, "/nl/pricing"
  end
end
