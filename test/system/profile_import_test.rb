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
    original_firm = @account.firm.attributes
    click_button "Get details from advocaat.be"
    assert_selector "form[data-unsaved-changes='true']", visible: :all
    wait_for_language_menu
    assert_text "Details loaded. Review them, then save."
    assert_equal 1, @import_calls.length
    assert_nil @account.firm.reload.phone
    assert_nil @account.profile.reload.availability_note
    assert_field "Availability", with: "Keep my unsaved availability"
    assert_no_selector "[name^='firm[']", visible: :all
    assert_field "Languages", with: "NL, FR"

    find(".language-menu summary").click
    dismiss_confirm I18n.t("marketing.language_switch_warning", locale: :en) do
      find(".language-menu a[hreflang='fr']").click
    end
    assert_current_path settings_path(locale: :en)
    assert_field "Availability", with: "Keep my unsaved availability"
    assert_no_selector "[name^='firm[']", visible: :all

    click_button "Save"
    assert_selector "form[data-unsaved-changes='false']", visible: :all
    assert_text "Changes saved."
    assert_equal original_firm, @account.firm.reload.attributes
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
    fill_in "Languages", with: "NL, FR"
    find_field("Languages").send_keys(:enter)
    assert_text "Changes saved."
    assert_equal %w[NL FR], @account.profile.reload.spoken_languages
    assert_nil @account.firm.reload.phone
    assert_empty @import_calls
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
