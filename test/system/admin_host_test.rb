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
end
