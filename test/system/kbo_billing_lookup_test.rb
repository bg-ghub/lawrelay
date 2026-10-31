require "application_system_test_case"
require "timeout"
require_relative "../support/marketplace_test_factory"

class KboBillingLookupTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    assert_equal :test, ActionMailer::Base.delivery_method
    @account = create_marketplace_account(prefix: "kbobrowser")
    @account.firm.update!(billing_email: "invoices-kbo@example.test", address_line_1: "Manual Billing Street 1", postal_code: "9000", city: "Gent")
    @original_request = BusinessRegistry::PublicLookup.instance_method(:perform_request)
    @requests = Queue.new
    @gate = { hold: false, entered: Queue.new, release: Queue.new }
    requests = @requests
    gate = @gate
    response = Rails.root.join("test/fixtures/files/kbo_company.html").binread
    BusinessRegistry::PublicLookup.define_method(:perform_request) do |uri, request|
      requests << [ uri, request ]
      if gate[:hold]
        gate[:entered] << true
        gate[:release].pop
      end
      [ 200, response ]
    end
    BusinessRegistry::PublicLookup.send(:private, :perform_request)
  end

  teardown do
    @gate&.fetch(:release)&.push(true)
    if @original_request
      BusinessRegistry::PublicLookup.define_method(:perform_request, @original_request)
      BusinessRegistry::PublicLookup.send(:private, :perform_request)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    if @account
      AuditEvent.where(actor_user_id: @account.user.id).delete_all
      @account.user.destroy!
      @account.firm.destroy!
    end
  end

  test "settings lookup uses the real public source parser and saves only after review" do
    original_firm = @account.firm.reload.attributes
    sign_in
    visit settings_path(locale: :en)
    wait_for_lookup
    fill_in "Enterprise number", with: "BE 1234.567.894"
    fill_in "Billing email", with: "my-invoice-mailbox@example.test"
    fill_in "Phone", with: "+3225550199"
    fill_in "Availability", with: "Keep my unsaved availability"
    click_button "Get CBE details"

    assert_text "Details loaded. Check them before saving."
    assert_field "Company name", with: "TEST CBE Company"
    assert_field "Enterprise number", with: "1234567894"
    assert_field "VAT number", with: "BE 1234567894"
    assert_field "Address", with: "TEST Registerstraat 12 / 3"
    assert_field "Postcode", with: "1000"
    assert_field "City", with: "Brussel"
    assert_field "Billing email", with: "my-invoice-mailbox@example.test"
    assert_field "Phone", with: "+3225550199"
    assert_field "Availability", with: "Keep my unsaved availability"
    assert_field "First name", with: @account.user.first_name
    assert_field "Last name", with: @account.user.last_name
    assert_text @account.user.email_address
    assert_selector ".business-lookup__source", text: I18n.l(Date.new(2026, 10, 29), locale: :en)
    assert_not_empty find("input[name='firm[kbo_lookup_token]']", visible: :all).value
    assert_selector "form[data-unsaved-changes='true']", visible: :all
    assert_equal original_firm, @account.firm.reload.attributes
    assert_nil @account.profile.reload.availability_note
    assert_requested_enterprise

    click_button "Save"

    assert_text "Changes saved."
    assert_equal "TEST CBE Company", @account.firm.reload.name
    assert_equal "TEST Registerstraat 12 / 3", @account.firm.address_line_1
    assert_equal "my-invoice-mailbox@example.test", @account.firm.billing_email
    assert_equal "2026-10-29", @account.firm.kbo_details.fetch("snapshot_date")
    assert_equal %w[address_line_1 city enterprise_number name postal_code], @account.firm.kbo_details.fetch("fields").sort
    assert_equal "Keep my unsaved availability", @account.profile.reload.availability_note
    assert_predicate @account.user.reload, :marketplace_verified?
  end

  test "assignment and signup previews preserve other form fields in every language" do
    original_firm = @account.firm.reload.attributes
    sign_in
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)

    %i[nl fr de en].each do |locale|
      visit new_assignment_path(locale:)
      wait_for_lookup(locale:)
      fill_in "assignment_title", with: "Synthetic assignment #{locale}"
      fill_in "assignment_invoice_enterprise_number", with: "BE 1234.567.894"
      fill_in "assignment_invoice_email", with: "assignment-invoice@example.test"
      click_button I18n.t("business_lookup.button", locale:)

      assert_text I18n.t("business_lookup.loaded", locale:)
      assert_field "assignment_invoice_name", with: "TEST CBE Company"
      assert_field "assignment_invoice_vat_number", with: "BE 1234567894"
      assert_selector "#assignment_invoice_vat_number[readonly]:not([name])"
      assert_field "assignment_invoice_address_line_1", with: expected_address(locale)
      assert_field "assignment_invoice_email", with: "assignment-invoice@example.test"
      assert_field "assignment_title", with: "Synthetic assignment #{locale}"
      assert_field "assignment_fee_cents", with: ""
      assert_not_empty find("input[name='assignment[kbo_lookup_token]']", visible: :all).value
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_no_text(/translation missing/i)
    end
    assert_equal original_firm, @account.firm.reload.attributes
    assert_empty @account.user.created_assignments

    Capybara.reset_sessions!
    visit new_registration_path(locale: :en)
    click_button I18n.t("signup_profile.manual", locale: :en)
    wait_for_lookup
    fill_in "registration_first_name", with: "Alex"
    fill_in "registration_last_name", with: "Example"
    fill_in "registration_email_address", with: "new-lawyer@example.test"
    fill_in "registration_password", with: "Synthetic-password1!"
    fill_in "registration_password_confirmation", with: "Synthetic-password1!"
    fill_in "registration_enterprise_number", with: "1234567894"
    count = User.count
    click_button "Get CBE details"

    assert_text "Details loaded. Check them before saving."
    assert_field "registration_firm_name", with: "TEST CBE Company"
    assert_field "registration_address_line_1", with: expected_address(:en)
    assert_field "registration_postal_code", with: "1000"
    assert_field "registration_city", with: "Brussel"
    assert_field "registration_first_name", with: "Alex"
    assert_field "registration_last_name", with: "Example"
    assert_field "registration_email_address", with: "new-lawyer@example.test"
    assert_field "registration_password", with: "Synthetic-password1!"
    assert_not_empty find("input[name='registration[kbo_lookup_token]']", visible: :all).value
    assert_equal count, User.count
  end

  test "a delayed lookup never overwrites details edited while waiting" do
    sign_in
    visit settings_path(locale: :en)
    wait_for_lookup
    fill_in "Enterprise number", with: "1234567894"
    @gate[:hold] = true
    click_button "Get CBE details"
    Timeout.timeout(Capybara.default_max_wait_time) { @gate[:entered].pop }
    assert_button "Loading…", disabled: true
    fill_in "Company name", with: "My manual correction"
    @gate[:release] << true

    assert_text "Your details changed. Look up the number again."
    assert_field "Company name", with: "My manual correction"
    assert_field "Address", with: "Manual Billing Street 1"
    assert_equal "", find("input[name='firm[kbo_lookup_token]']", visible: :all).value
    assert_button "Get CBE details", disabled: false
    assert_not_equal "My manual correction", @account.firm.reload.name
  ensure
    @gate&.fetch(:release)&.push(true)
  end

  private

  def sign_in
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  def wait_for_lookup(locale: :en)
    assert_button I18n.t("business_lookup.button", locale:)
    Selenium::WebDriver::Wait.new(timeout: Capybara.default_max_wait_time).until do
      page.evaluate_script("!!window.Stimulus?.getControllerForElementAndIdentifier(document.querySelector('[data-controller~=business-lookup]'), 'business-lookup')")
    end
  end

  def expected_address(_locale)
    "TEST Registerstraat 12 / 3"
  end

  def assert_requested_enterprise
    uri, request = @requests.pop
    assert_equal "https", uri.scheme
    assert_equal "kbopub.economie.fgov.be", uri.host
    assert_equal "/kbopub/toonondernemingps.html", uri.path
    assert_equal({ "ondernemingsnummer" => "1234567894", "lang" => "nl" }, URI.decode_www_form(uri.query).to_h)
    assert_instance_of Net::HTTP::Get, request
    assert_nil request.body
    assert_nil request["Authorization"]
  end
end
