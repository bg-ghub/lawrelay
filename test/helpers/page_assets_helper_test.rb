require "test_helper"

class PageAssetsHelperTest < ActionView::TestCase
  tests PageAssetsHelper
  self.fixture_table_names = []

  def controller_path = @page_controller || "home"
  def action_name = @page_action || "index"
  def admin_host? = @admin_host || false

  test "public pages include only their shared and public styles" do
    assert_equal %w[application footer_project home_pathways marketing_copy product_bar pwa_install shared_flash], page_stylesheet_names
    @page_controller, @page_action = "pages", "court_cover"
    assert_equal %w[application footer_project product_bar product_pages pwa_install shared_flash], page_stylesheet_names
    @page_action = "privacy"
    assert_equal %w[application footer_project legal_pages product_bar pwa_install shared_flash], page_stylesheet_names
  end

  test "private components retain their dependencies and original alphabetical cascade" do
    cases = {
      "registrations" => %w[account_flow auth-copy profile_import registration_profile],
      "verification_status" => %w[account_flow profile_import verification_status],
      "email_access_requests" => %w[account_flow profile_import],
      "sessions" => %w[auth-copy accessibility_beta],
      "passwords" => %w[auth-copy],
      "geo_challenges" => %w[auth-copy],
      "account_deletions" => %w[account_deletion],
      "two_factor_authentications" => %w[admin_mfa two_factor],
      "settings" => %w[profile_import profile_preferences searchable_select two_factor],
      "dashboard" => %w[assignment_rates profile_import profile_preferences proposal_location proposal_travel],
      "assignments" => %w[court_picker searchable_select assignment_filters proposal_location proposal_travel],
      "proposals" => %w[court_picker searchable_select profile_import],
      "notifications" => %w[notifications],
      "reports" => %w[searchable_select],
      "privacy_requests" => %w[searchable_select],
      "billing" => %w[business_lookup searchable_select],
      "admin/users" => %w[admin_users admin_navigation admin_shell searchable_select],
      "admin/mfa" => %w[admin_mfa two_factor],
      "admin/registry_statuses" => %w[registry_status]
    }
    cases.each do |controller, required|
      @page_controller = controller
      required.each { |name| assert_includes page_stylesheet_names, name, controller }
      assert_equal page_stylesheet_names.sort, page_stylesheet_names
      assert_equal page_stylesheet_names.uniq, page_stylesheet_names
    end
  end

  test "each stylesheet has an explicit page or shared home" do
    scenarios = [ [ "home", "index" ], [ "pages", "privacy" ], [ "pages", "pricing" ], [ "pages", "court_cover" ] ]
    scenarios += %w[registrations verification_status sessions account_deletions two_factor_authentications settings assignments dashboard notifications billing admin/users].map { |controller| [ controller, "show" ] }
    selected = scenarios.flat_map do |controller, action|
      @page_controller, @page_action = controller, action
      page_stylesheet_names
    end.uniq.sort
    existing = Dir[Rails.root.join("app/assets/stylesheets/*.css")].map { |path| File.basename(path, ".css") }.sort
    assert_equal existing, selected

    @admin_host = true
    @page_controller = "admin/users"
    assert_not_includes page_stylesheet_names, "product_bar"
    assert_not_includes page_stylesheet_names, "pwa_install"
    assert shared_stylesheet?("application")
    refute shared_stylesheet?("registration_profile")
  end
end
