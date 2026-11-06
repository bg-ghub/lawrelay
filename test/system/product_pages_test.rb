require "application_system_test_case"

class ProductPagesTest < ApplicationSystemTestCase
  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
  end

  test "public product pages fit narrow screens and preserve the page when switching language" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      %i[court_cover legal_assignments].each do |product|
        visit public_send("#{product}_path", locale:)
        assert_selector ".product-page h1", text: I18n.t("product_pages.#{product}.heading", locale:)
        assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
        assert_selector ".product-page__actions a", count: 4
      end
    end

    find(".language-menu summary").click
    find(".language-menu a[hreflang='fr']").click
    assert_current_path legal_assignments_path(locale: :fr)
    within ".product-page__related" do
      click_link I18n.t("product_pages.links.court_cover", locale: :fr)
    end
    assert_current_path court_cover_path(locale: :fr)
    assert_selector ".product-page h1", text: I18n.t("product_pages.court_cover.heading", locale: :fr)
  end
end
