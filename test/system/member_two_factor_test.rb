require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class MemberTwoFactorTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup { @account = create_marketplace_account(prefix: "twofactorbrowser") }

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    AuditEvent.where(actor_user_id: @account.user.id).delete_all
    @account.user.destroy!
    @account.firm.destroy!
  end

  test "a member enables QR two factor signs in with recovery and can turn it off" do
    sign_in
    visit settings_path(locale: :en)
    click_link "Manage two-factor authentication"
    fill_in "current_password", with: "password1234"
    click_button "Continue"
    assert_current_path setup_two_factor_authentication_path(locale: :en)
    assert_selector "img.mfa-qr"
    assert page.evaluate_script("document.querySelector('img.mfa-qr').naturalWidth > 0")
    assert_no_selector ".mfa-manual[open]"

    assert_mobile_pages
    visit setup_two_factor_authentication_path(locale: :en)
    secret = @account.user.reload.two_factor_pending_secret
    fill_in "mfa_code", with: ROTP::TOTP.new(secret, issuer: "LawRelay").now
    click_button "Enable two-factor authentication"
    assert_selector ".recovery-codes code", count: 10
    codes = all(".recovery-codes code").map(&:text)
    assert_predicate @account.user.reload, :two_factor_enabled?
    click_link "I’ve saved my codes"
    assert_current_path settings_path(locale: :en)
    assert_text "Two-factor authentication is on."

    sign_out
    sign_in
    assert_current_path challenge_two_factor_authentication_path(locale: :en)
    visit settings_path(locale: :en)
    assert_current_path challenge_two_factor_authentication_path(locale: :en)
    use_recovery(codes.first)
    assert_current_path settings_path(locale: :en)
    assert_equal 9, @account.user.reload.two_factor_recovery_codes_remaining

    sign_out
    sign_in
    use_recovery(codes.first)
    assert_current_path verify_two_factor_authentication_path(locale: :en)
    assert_text "That code is invalid or has already been used."
    use_recovery(codes.second)
    assert_current_path dashboard_path(locale: :en)

    visit two_factor_authentication_path(locale: :en)
    fill_in "current_password", with: "password1234"
    find(".mfa-manual summary").click
    fill_in "recovery_code", with: codes.third
    click_button "Turn off two-factor authentication"
    assert_text "Two-factor authentication is off."
    assert_not_predicate @account.user.reload, :two_factor_enabled?
    sign_out
    sign_in
    assert_current_path dashboard_path(locale: :en)
  end

  private

  def sign_in
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    expected = @account.user.reload.two_factor_enabled? ? challenge_two_factor_authentication_path(locale: :en) : dashboard_path(locale: :en)
    assert_current_path expected
  end

  def sign_out
    within(".site-header") { click_button "Sign out" }
    assert_current_path new_session_path(locale: :en)
  end

  def use_recovery(code)
    find(".mfa-manual summary").click unless page.has_selector?(".mfa-manual[open]")
    fill_in "recovery_code", with: code
    click_button "Continue"
  end

  def assert_mobile_pages
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      visit setup_two_factor_authentication_path(locale: locale)
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_selector "img.mfa-qr", count: 1
      assert_no_text(/translation missing/i)
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
  end
end
