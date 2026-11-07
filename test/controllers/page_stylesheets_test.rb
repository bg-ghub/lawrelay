require "test_helper"
require_relative "../support/marketplace_test_factory"

class PageStylesheetsTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  test "public pages omit private assets while keeping public styles dynamic" do
    { "/en" => "home_pathways", "/en/court-cover" => "product_pages", "/fr/privacy" => "legal_pages" }.each do |path, extra|
      get path
      assert_response :success
      assert_includes stylesheet_names, extra
      assert_includes stylesheet_names, "pwa_install"
      assert_not_includes stylesheet_names, "admin_users"
      assert_not_includes stylesheet_names, "registration_profile"
      assert_not_includes stylesheet_names, "account_flow"
      assert_select "link[data-lawrelay-stylesheet='application'][data-turbo-track='reload']", count: 1
      assert_select "link[data-lawrelay-stylesheet='#{extra}'][data-turbo-track='dynamic']", count: 1
      assert_select "meta[name='lawrelay-stylesheets-end']", count: 1
      assert_equal stylesheet_names.sort, stylesheet_names
    end
  end

  test "anonymous account and recovery screens load their form styles" do
    { new_registration_path(locale: :en) => %w[auth-copy account_flow profile_import registration_profile],
      new_session_path(locale: :en) => %w[auth-copy],
      new_password_path(locale: :en) => %w[auth-copy],
      geo_challenge_path(locale: :en) => %w[auth-copy] }.each do |path, required|
      get path
      assert_response :success
      required.each { |name| assert_includes stylesheet_names, name }
      assert_not_includes stylesheet_names, "admin_users"
    end
  end

  test "member workflows retain profile search assignment travel and notification styles" do
    account = create_marketplace_account(prefix: "css-member")
    assignment = create_assignment_for(account)
    sign_in_as(account.user)
    { dashboard_path(locale: :en) => %w[assignment_rates proposal_location],
      settings_path(locale: :en) => %w[profile_import profile_preferences searchable_select two_factor],
      assignments_path(locale: :en) => %w[assignment_filters searchable_select],
      new_assignment_path(locale: :en) => %w[court_picker searchable_select accessibility_beta],
      assignment_path(assignment, locale: :en) => %w[profile_import profile_preferences proposal_location proposal_travel],
      notifications_path(locale: :en) => %w[notifications],
      privacy_requests_path(locale: :en) => %w[searchable_select],
      account_deletion_path(locale: :en) => %w[account_deletion],
      two_factor_authentication_path(locale: :en) => %w[admin_mfa two_factor] }.each do |path, required|
      get path
      assert_response :success
      required.each { |name| assert_includes stylesheet_names, name }
      assert_not_includes stylesheet_names, "admin_users"
    end
  end

  test "pending verification and administrator screens have their own styles" do
    original_admin_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    account = create_marketplace_account(prefix: "css-pending", verified: false, email_verified: false)
    sign_in_as(account.user)
    get verification_status_path(locale: :en)
    assert_response :success
    %w[account_flow verification_status profile_import].each { |name| assert_includes stylesheet_names, name }

    admin = User.create!(email_address: "css-admin@example.test", password: "password1234", first_name: "Admin", last_name: "CSS", system_role: "admin")
    ENV["LAWRELAY_ADMIN_USER_ID"] = admin.id.to_s
    host! SiteHosts.admin_host
    get admin_login_path(locale: :en)
    assert_response :success
    post admin_login_path(locale: :en), params: { password: "password1234" }
    assert_redirected_to admin_users_path(locale: :en)
    admin.sessions.order(:id).last.mark_admin_mfa_verified!
    get admin_users_path(locale: :en)
    assert_response :success
    %w[admin_users admin_navigation admin_shell searchable_select].each { |name| assert_includes stylesheet_names, name }
    assert_not_includes stylesheet_names, "product_bar"
    assert_not_includes stylesheet_names, "pwa_install"
    assert_not_includes stylesheet_names, "registration_profile"
  ensure
    original_admin_id.nil? ? ENV.delete("LAWRELAY_ADMIN_USER_ID") : ENV["LAWRELAY_ADMIN_USER_ID"] = original_admin_id
  end

  test "error responses keep their minimal standalone layout" do
    get "/404.html"
    assert_response :success
    assert_select "meta[name='robots']"
    assert_empty stylesheet_names
  end

  private

  def stylesheet_names
    css_select("link[data-lawrelay-stylesheet]").map { |link| link["data-lawrelay-stylesheet"] }
  end
end
