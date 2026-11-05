require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class MobileMemberNavigationTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "mobilenavigationsettings")
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    @account.user.reload.destroy!
    @account.firm.reload.destroy!
  end

  test "members can open settings from the collapsed navigation in every language" do
    [ 320, 1265 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 950, deviceScaleFactor: 1, mobile: false)

      %i[nl fr de en].each do |locale|
        visit dashboard_path(locale:)
        assert_equal width, page.evaluate_script("window.innerWidth")
        assert_no_selector ".header-login[href='#{settings_path(locale:)}']"

        find(".menu-toggle").click
        assert_selector "#primary-navigation.is-open"
        within("#primary-navigation") do
          click_link I18n.t("settings.heading", locale:), exact: true
        end

        assert_current_path settings_path(locale:)
        assert_selector "h1", text: I18n.t("settings.heading", locale:), exact_text: true
        assert_no_selector "#primary-navigation.is-open"
      end
    end
  end
end
