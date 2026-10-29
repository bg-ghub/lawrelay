require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::ReviewInterfaceTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @previous_environment = ENV.slice("APP_HOST", "ADMIN_HOST", "APP_PROTOCOL", "LAWRELAY_RELEASE_MODE")
    ENV["APP_HOST"] = "lawrelay.example"
    ENV["ADMIN_HOST"] = "admin.lawrelay.example"
    ENV["APP_PROTOCOL"] = "https"
    ENV["LAWRELAY_RELEASE_MODE"] = "beta"
    host! "admin.lawrelay.example"
    https!
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @member = create_marketplace_account(prefix: "reviewmember").user
    sign_in_as(@admin, admin_mfa: true)
  end

  teardown do
    %w[APP_HOST ADMIN_HOST APP_PROTOCOL LAWRELAY_RELEASE_MODE].each do |key|
      @previous_environment.key?(key) ? ENV[key] = @previous_environment[key] : ENV.delete(key)
    end
  end

  test "user details show optional two factor status rather than administrator MFA" do
    %i[nl fr de en].each do |locale|
      get admin_user_path(@member, locale: locale)
      assert_response :success
      assert_select ".admin-user-overview dt", text: I18n.t("two_factor.heading", locale: locale)
      assert_select ".admin-user-overview dd", text: I18n.t("two_factor.status_off", locale: locale)
      assert_select ".admin-user-overview dt", text: I18n.t("admin.users.fields.mfa", locale: locale), count: 0
    end
    secret = @member.begin_two_factor_setup!(password: "password1234")
    @member.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    get admin_user_path(@member, locale: :en)
    assert_select ".admin-user-overview dd", text: I18n.t("two_factor.status_on", locale: :en)
    assert_select ".mfa-secret, .mfa-uri, .mfa-qr, .recovery-codes", count: 0
  end

  test "verification navigation stays in administration and hides archived beta controls" do
    %i[nl fr de en].each do |locale|
      get admin_verifications_path(locale: locale)
      assert_response :success
      assert_select "title", text: I18n.t("admin.verifications.title", locale: locale)
      assert_select ".dashboard-heading a[href='#{admin_users_path(locale: locale)}']", count: 1
      assert_select "a[href='#{admin_founding_accesses_path(locale: locale)}']", count: 0
      assert_select "a[href='#{dashboard_path(locale: locale)}']", count: 0
      assert_select "a[href='https://lawrelay.example/#{locale}']", count: 1
    end
  end

  test "administrators cannot be processed through professional verification" do
    assert_no_difference "AuditEvent.count" do
      patch admin_verification_path(@admin, locale: :en), params: { decision: "approve" }
    end
    assert_response :not_found
    assert_predicate @admin.reload, :system_admin?
  end
end
