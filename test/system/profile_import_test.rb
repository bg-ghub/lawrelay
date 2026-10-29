require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class ProfileImportTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "profileimportbrowser")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    @original_import = Directory::ProfileImport.method(:call)
    @import_calls = []
    calls = @import_calls
    Directory::ProfileImport.define_singleton_method(:call) do |**arguments|
      calls << arguments
      Directory::ProfileImport::Result.new(status: :ok,
        profile_attributes: { spoken_languages: %w[NL FR], practice_areas: [ "Family law" ] },
        firm_attributes: { phone: "+3225550101", address_line_1: "Example Street 10", postal_code: "1000", city: "Brussel" })
    end
  end

  teardown do
    Directory::ProfileImport.define_singleton_method(:call, @original_import)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    AuditEvent.where(actor_user_id: @account.user.id).delete_all
    @account.user.destroy!
    @account.firm.destroy!
  end

  test "the real import button previews current form values and Save persists them" do
    sign_in
    visit settings_path(locale: :en)
    fill_in "Availability", with: "Keep my unsaved availability"
    click_button "Get details from advocaat.be"
    assert_text "Details loaded. Review them, then save."
    assert_equal 1, @import_calls.length
    assert_nil @account.firm.reload.phone
    assert_nil @account.profile.reload.availability_note
    assert_field "Availability", with: "Keep my unsaved availability"
    assert_field "Phone", with: "+3225550101"
    assert_field "Languages", with: "NL, FR"

    click_button "Save"
    assert_text "Changes saved."
    assert_equal "+3225550101", @account.firm.reload.phone
    assert_equal "Keep my unsaved availability", @account.profile.reload.availability_note
    assert_equal %w[NL FR], @account.profile.spoken_languages
    assert_predicate @account.profile, :verified?
    assert_predicate @account.user.reload, :email_verified?
  end

  test "Enter keeps the ordinary Save action instead of importing" do
    sign_in
    visit settings_path(locale: :en)
    fill_in "Phone", with: "+3225550199"
    find_field("Phone").send_keys(:enter)
    assert_text "Changes saved."
    assert_equal "+3225550199", @account.firm.reload.phone
    assert_empty @import_calls
  end

  test "the import control fits narrow settings in all four languages" do
    sign_in
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      visit settings_path(locale: locale)
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_button I18n.t("profile_import.button", locale: locale)
      assert_no_text(/translation missing/i)
    end
    assert_empty @import_calls
  end

  private

  def sign_in
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end
end
