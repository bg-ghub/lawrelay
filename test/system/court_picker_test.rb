require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class CourtPickerTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "courtpicker")
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
    visit new_assignment_path(locale: :en)
    assert_selector "[data-controller='court-picker'][data-court-picker-options-value]"
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    if @account
      AuditEvent.where(actor_user_id: @account.user.id).delete_all
      @account.user.destroy!
      @account.firm.destroy!
    end
  end

  test "court list filters by partial type place and accents and fills a real division" do
    find("#assignment_court").click
    assert_selector "#assignment-court-options [role='option']", count: 320
    fill_in "assignment_court", with: "antwerpen"
    assert_selector "#assignment-court-options [role='option']", minimum: 10
    page.execute_script("document.querySelector('#assignment_court').scrollIntoView({block: 'center', behavior: 'instant'})")
    page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-desktop.png").to_s)
    fill_in "assignment_court", with: "entreprise anvers malines"

    expected = "Enterprise court Antwerp — division Mechelen"
    assert_selector "#assignment-court-options [role='option']", count: 1, text: expected
    find("#assignment-court-options [role='option']", text: expected).click
    assert_field "assignment_court", with: expected
    assert_field "assignment_city", with: "Mechelen"
    assert_selector "#assignment_court[aria-expanded='false']"

    fill_in "assignment_court", with: "liege police"
    assert_field "assignment_city", with: ""
    assert_selector "#assignment-court-options [role='option']", text: "Police court Liège — division Liège"
    find("#assignment_court").send_keys(:arrow_down, :enter)
    assert_match(/Police court Liège/, find("#assignment_court").value)
    assert_not_empty find("#assignment_city").value
  end

  test "keyboard dismissal manual venue and kind switches preserve the normal form" do
    fill_in "assignment_court", with: "enterprise court mechelen"
    find("#assignment_court").send_keys(:arrow_down)
    assert_selector "#assignment_court[aria-activedescendant]"
    find("#assignment_court").send_keys(:escape)
    assert_selector "#assignment_court[aria-expanded='false']"
    assert_field "assignment_court", with: "enterprise court mechelen"

    fill_in "assignment_court", with: "Synthetic notary office"
    assert_text "No results. Enter the court or venue and city yourself."
    fill_in "assignment_city", with: "Test city"
    assert_field "assignment_court", with: "Synthetic notary office"

    find("label.kind-option", text: "Legal task").click
    assert_no_selector "#assignment_court", visible: :visible
    find("label.kind-option", text: "Court cover").click
    assert_field "assignment_court", with: "Synthetic notary office"
    assert_field "assignment_city", with: "Test city"
  end

  test "locales show their court types and language-specific Brussels options on narrow screens" do
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)

    %i[nl fr de en].each do |locale|
      visit new_assignment_path(locale:)
      fill_in "assignment_court", with: "police bruxelles"
      options = all("#assignment-court-options [role='option']")
      assert_equal 2, options.size
      assert options.all? { |option| option.text.include?(I18n.t("court_picker.types.police", locale:)) }
      if locale == :nl
        page.execute_script("document.querySelector('#assignment_court').scrollIntoView({block: 'center', behavior: 'instant'})")
        page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-nl-320.png").to_s)
      end
      find("#assignment_court").send_keys(:arrow_down, :enter)
      assert_field "assignment_city", with: { nl: "Brussel", fr: "Bruxelles", de: "Brüssel", en: "Brussels" }.fetch(locale)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_no_text(/translation missing/i)
    end
  end
end
