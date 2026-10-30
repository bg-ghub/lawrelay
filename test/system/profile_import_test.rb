require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class ProfileImportTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "profileimportbrowser")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    @original_fetch = Directory::ProfileImport.instance_method(:fetch_html)
    @import_calls = []
    calls = @import_calls
    html = <<~HTML
      <main id="main">
        <h1>#{ERB::Util.html_escape(@account.user.full_name)}</h1>
        <section><h2>Talen</h2><p>Nederlands, Frans</p></section>
        <section><h2>Voorkeurmateries</h2><p>Family law</p></section>
        <section><h2>Contact</h2><address>Example Street 10<br>1000 Brussel</address><a href="tel:+3225550101">Phone</a></section>
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

  test "the real import button previews current form values and Save persists them" do
    sign_in
    visit settings_path(locale: :en)
    fill_in "Availability", with: "Keep my unsaved availability"
    fill_in "Phone", with: "+3225550199"
    fill_in "Address", with: "Billing Street 12"
    click_button "Get details from advocaat.be"
    assert_selector "form[data-unsaved-changes='true']", visible: :all
    wait_for_language_menu
    assert_text "Details loaded. Review them, then save."
    assert_equal 1, @import_calls.length
    assert_nil @account.firm.reload.phone
    assert_nil @account.profile.reload.availability_note
    assert_field "Availability", with: "Keep my unsaved availability"
    assert_field "Phone", with: "+3225550199"
    assert_field "Address", with: "Billing Street 12"
    assert_field "Languages", with: "NL, FR"

    find(".language-menu summary").click
    dismiss_confirm I18n.t("marketing.language_switch_warning", locale: :en) do
      find(".language-menu a[hreflang='fr']").click
    end
    assert_current_path settings_path(locale: :en)
    assert_field "Availability", with: "Keep my unsaved availability"
    assert_field "Phone", with: "+3225550199"
    assert_field "Address", with: "Billing Street 12"

    click_button "Save"
    assert_selector "form[data-unsaved-changes='false']", visible: :all
    assert_text "Changes saved."
    assert_equal "+3225550199", @account.firm.reload.phone
    assert_equal "Billing Street 12", @account.firm.address_line_1
    assert_equal "Keep my unsaved availability", @account.profile.reload.availability_note
    assert_equal %w[NL FR], @account.profile.spoken_languages
    assert_predicate @account.profile, :verified?
    assert_predicate @account.user.reload, :email_verified?

    wait_for_language_menu
    find(".language-menu summary").click
    find(".language-menu a[hreflang='fr']").click
    assert_current_path settings_path(locale: :fr)
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

  test "enterprise number derives a read-only VAT preview and official lookup in every language" do
    sign_in
    %i[nl fr de en].each do |locale|
      visit settings_path(locale: locale)
      fill_in I18n.t("auth.fields.enterprise_number", locale: locale), with: "BE 1234.567.894"
      assert_field I18n.t("auth.fields.enterprise_number", locale: locale), with: "1234567894"
      assert_field I18n.t("auth.fields.vat_number", locale: locale), with: "BE 1234567894"
      assert_selector "input[data-company-number-target='vat'][readonly]:not([name])"
      assert_selector "a.company-lookup[href='https://kbopub.economie.fgov.be/kbopub/toonondernemingps.html?ondernemingsnummer=1234567894&lang=#{locale}'][target='_blank'][rel='noopener noreferrer']"

      fill_in I18n.t("auth.fields.enterprise_number", locale: locale), with: "12345678941"
      assert_field I18n.t("auth.fields.vat_number", locale: locale), with: ""
      assert_selector "a.company-lookup[aria-disabled='true']:not([href])"
    end

    fill_in "Enterprise number", with: "1234567890"
    click_button "Save"
    assert_text "Enterprise number is invalid"
    fill_in "Enterprise number", with: "1234567894"
    fill_in "Company name", with: "My default invoice recipient"
    click_button "Save"
    assert_text "Changes saved."
    assert_equal "BE1234567894", @account.firm.reload.vat_number
    assert_predicate @account.user.reload, :marketplace_verified?
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
