require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AdminHostTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @previous_environment = ENV.slice("APP_HOST", "ADMIN_HOST", "APP_PROTOCOL", "LAWRELAY_ADMIN_USER_ID")
    @admin = User.create!(first_name: "Host", last_name: "Operator", email_address: "host-operator-#{SecureRandom.hex(6)}@example.test",
      password: "admin-password1234", system_role: "admin", email_verified_at: Time.current, locale: "en")
    @secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(@secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    @member = create_marketplace_account(prefix: "hostbrowsermember")

    visit "/up"
    port = Capybara.current_session.server.port
    @main_origin = "http://main.localhost:#{port}"
    @admin_origin = "http://admin.localhost:#{port}"
    ENV["APP_HOST"] = "main.localhost:#{port}"
    ENV["ADMIN_HOST"] = "admin.localhost"
    ENV["APP_PROTOCOL"] = "http"
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    %w[APP_HOST ADMIN_HOST APP_PROTOCOL LAWRELAY_ADMIN_USER_ID].each do |key|
      @previous_environment.key?(key) ? ENV[key] = @previous_environment[key] : ENV.delete(key)
    end
    user_ids = [ @admin&.id, @member&.user&.id ].compact
    AuditEvent.where(actor_user_id: user_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: @member&.firm&.id).delete_all
  end

  test "member and administrator browser sessions stay independent across hosts" do
    visit "#{@main_origin}/en/session/new"
    fill_in "email_address", with: @member.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)

    visit "#{@admin_origin}/en"
    assert_current_path admin_login_path(locale: :en)
    assert_no_selector "input[type='email']"
    assert_no_selector ".product-bar"
    fill_in "password", with: "admin-password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path admin_mfa_challenge_path(locale: :en)
    fill_in "mfa_code", with: ROTP::TOTP.new(@secret, issuer: "LawRelay").now
    click_button "Continue"
    assert_current_path admin_users_path(locale: :en)
    assert_selector ".admin-navigation"
    assert_selector ".admin-site-footer .footer-project__version", text: LawRelay::VERSION
    assert_equal "admin.localhost", URI.parse(page.current_url).host

    assert_admin_header_fits_on_mobile

    visit "#{@main_origin}/en/dashboard"
    assert_current_path dashboard_path(locale: :en)
    assert_selector ".header-login", text: @member.user.full_name

    visit "#{@admin_origin}/en/admin/users"
    assert_selector "h1", text: "Users"
    within(".admin-site-header") { click_button "Sign out" }
    assert_current_path admin_login_path(locale: :en)

    visit "#{@main_origin}/en/dashboard"
    assert_current_path dashboard_path(locale: :en)
    assert_selector ".header-login", text: @member.user.full_name
  end

  private

  def assert_admin_header_fits_on_mobile
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)

    %i[nl fr de en].each do |locale|
      visit "#{@admin_origin}/#{locale}/admin/users"
      assert_selector ".admin-navigation"
      assert_equal 320, page.evaluate_script("window.innerWidth"), "The viewport must actually be 320px"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320, "Admin layout overflows in #{locale} at 320px"
      assert_selector ".admin-site-header a[href='#{@main_origin}/#{locale}']", text: I18n.t("admin.navigation.site", locale: locale)
      assert_selector ".admin-site-header button", text: I18n.t("auth.sessions.sign_out", locale: locale)

      targets = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('.admin-site-header .header-actions > a, .admin-site-header .header-actions button, .admin-site-header summary')).map(element => {
          const rect = element.getBoundingClientRect();
          return { label: element.innerText.trim(), width: rect.width, height: rect.height };
        })
      JS
      assert_equal 3, targets.length
      targets.each do |target|
        assert_operator target.fetch("width"), :>=, 24, "#{locale} #{target.fetch('label')} needs a 24px target width"
        assert_operator target.fetch("height"), :>=, 24, "#{locale} #{target.fetch('label')} needs a 24px target height"
      end
      page.save_screenshot(Rails.root.join("tmp/screenshots/admin-host-fr-320.png")) if locale == :fr
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
  end
end
