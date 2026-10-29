require "application_system_test_case"

class AdminMfaSetupTest < ApplicationSystemTestCase
  setup do
    @previous_admin_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    @admin = User.create!(
      first_name: "QR", last_name: "Setup", email_address: "qr-admin-#{SecureRandom.hex(6)}@example.test",
      password: "admin-password1234", system_role: "admin", email_verified_at: Time.current, locale: "en"
    )
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
  end

  teardown do
    Capybara.reset_sessions!
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.browser.respond_to?(:execute_cdp)
    page.current_window.resize_to(1400, 1400)
    Session.where(user_id: @admin.id).delete_all
    AuditEvent.where(actor_user_id: @admin.id).delete_all
    @admin.destroy!
    @previous_admin_id ? ENV["LAWRELAY_ADMIN_USER_ID"] = @previous_admin_id : ENV.delete("LAWRELAY_ADMIN_USER_ID")
  end

  test "unconfigured admin can scan a local QR code at mobile width in every locale" do
    visit admin_login_path(locale: :en)
    fill_in "password", with: "admin-password1234"
    click_button I18n.t("admin.login.submit", locale: :en)
    assert_current_path admin_mfa_setup_path(locale: :en)

    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)

    %i[nl fr de en].each do |locale|
      visit admin_mfa_setup_path(locale: locale)
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_selector "img.mfa-qr[src^='data:image/png;base64,']"
      assert page.evaluate_script("document.querySelector('img.mfa-qr').complete && document.querySelector('img.mfa-qr').naturalWidth > 0"), "QR image must load"
      assert_no_selector "details[open]"
      assert_selector "details"
      page.save_screenshot(Rails.root.join("tmp/screenshots/admin-mfa-setup-320.png")) if locale == :en
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.browser.respond_to?(:execute_cdp)
    page.current_window.resize_to(1400, 1400)
  end
end
