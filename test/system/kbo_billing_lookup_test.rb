require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class KboBillingLookupTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "minimalassignmentbrowser")
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

  test "assignment forms fit a narrow viewport without company or invoice controls in every language" do
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)

    %i[nl fr de en].each do |locale|
      visit new_assignment_path(locale:)

      assert_no_selector "input[name^='assignment[invoice_']", visible: :all
      assert_no_selector "input[name='assignment[kbo_lookup_token]']", visible: :all
      assert_no_selector "[data-controller~='business-lookup']", visible: :all
      assert_no_selector "[data-controller~='company-number']", visible: :all
      assert_no_selector "#assignment_court_subtype", visible: :all
      assert_text I18n.t("company_minimization.private_invoice_details", locale:)
      assert_field "assignment_fee_cents", with: ""
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_no_text(/translation missing/i)
    end
    assert_empty @account.user.created_assignments
  end
end
