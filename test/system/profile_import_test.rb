require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class ProfileImportTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "profileimportbrowser")
    profile_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
    @account.profile.update!(directory_profile_url: profile_url, directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @account.user.full_name, directory_email: @account.user.email_address,
      directory_checked_at: Time.current, directory_email_verified_at: Time.current,
      directory_identity_digest: "directory-proof", spoken_languages: [ "NL" ], practice_areas: [ "Existing area" ])
    @original_fetch = Directory::ProfileImport.instance_method(:fetch_html)
    @sync_calls = []
    calls = @sync_calls
    html = <<~HTML
      <main id="main">
        <h1>#{ERB::Util.html_escape(@account.user.full_name)}</h1>
        <section><h2>Talen</h2><p>Nederlands, Frans</p></section>
        <section><h2>Voorkeurmateries</h2><p>Family law</p></section>
      </main>
    HTML
    Directory::ProfileImport.define_method(:fetch_html) do |uri|
      calls << uri.to_s
      html
    end
    Directory::ProfileImport.send(:private, :fetch_html)
  end

  teardown do
    Directory::ProfileImport.define_method(:fetch_html, @original_fetch)
    Directory::ProfileImport.send(:private, :fetch_html)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    AuditEvent.where(actor_user_id: @account.user.id).delete_all
    @account.user.destroy!
    @account.firm.destroy!
  end

  test "the refresh button persists directory values immediately" do
    sign_in
    visit settings_path(locale: :en)
    original_firm = @account.firm.attributes
    click_button I18n.t("profile_import.button", locale: :en)
    assert_text I18n.t("profile_import.updated", locale: :en)
    assert_equal 1, @sync_calls.length
    assert_nil @account.firm.reload.phone
    assert_equal %w[NL FR], @account.profile.reload.spoken_languages
    assert_equal [ "Family law" ], @account.profile.reload.practice_areas
    within ".directory-profile" do
      assert_text "NL, FR"
      assert_text "Family law"
    end
    page.refresh
    within ".directory-profile" do
      assert_text "NL, FR"
      assert_text "Family law"
    end
    assert_equal 1, @sync_calls.length
    assert_equal @account.user.email_address, @account.user.reload.email_address
    assert_equal "verified", @account.profile.reload.verification_status
    assert_equal [ "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a" ], @sync_calls
    assert_no_selector "[name^='firm[']", visible: :all
    assert_equal original_firm, @account.firm.reload.attributes
    assert_no_selector "input[name^='profile['], textarea[name^='profile[']", visible: :all
    assert_predicate @account.profile, :verified?
    assert_predicate @account.user.reload, :email_verified?
  end

  test "Enter keeps the ordinary Save action instead of importing" do
    sign_in
    visit settings_path(locale: :en)
    fill_in "First name", with: @account.user.first_name
    find_field("First name").send_keys(:enter)
    assert_text "Changes saved."
    assert_equal @account.user.first_name, @account.user.reload.first_name
    assert_nil @account.firm.reload.phone
    assert_empty @sync_calls
  end

  test "settings has no company or billing fields or official lookup in any language" do
    sign_in
    original_firm = @account.firm.attributes
    %i[nl fr de en].each do |locale|
      visit settings_path(locale:)
      assert_no_selector "[name^='firm[']", visible: :all
      assert_no_selector "[data-controller*='company-number'], [data-controller*='business-lookup']", visible: :all
      assert_no_button I18n.t("business_lookup.button", locale:)
    end
    assert_equal original_firm, @account.firm.reload.attributes
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
      assert_no_selector "input[name^='profile['], textarea[name^='profile[']", visible: :all
      assert_no_text(/translation missing/i)
    end
    assert_empty @sync_calls
  end

  private

  def wait_for_language_menu
    Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until do
      page.evaluate_script("!!window.Stimulus?.getControllerForElementAndIdentifier(document.querySelector('.language-menu'), 'language-menu')")
    end
  end

  def sign_in
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end
end
