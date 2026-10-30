require "test_helper"

class AnalyticsHelperTest < ActiveSupport::TestCase
  include AnalyticsHelper

  test "only public marketing actions are eligible for Umami" do
    assert umami_analytics_public_action?(controller_path: "home", action_name: "index")
    %w[privacy terms cookie_policy legal_notice].each do |action|
      assert umami_analytics_public_action?(controller_path: "pages", action_name: action)
    end

    refute umami_analytics_public_action?(controller_path: "pages", action_name: "pricing")
    refute umami_analytics_public_action?(controller_path: "assignments", action_name: "show")
    refute umami_analytics_public_action?(controller_path: "admin/users", action_name: "index")
    refute umami_analytics_public_action?(controller_path: "sessions", action_name: "new")
  end

  test "preferences are available on the main site but never on the admin host" do
    production = ActiveSupport::StringInquirer.new("production")

    assert umami_analytics_preferences_available?(environment: production, website_id: "website-id", admin: false)
    refute umami_analytics_preferences_available?(environment: production, website_id: "website-id", admin: true)
    refute umami_analytics_preferences_available?(environment: production, website_id: nil, admin: false)
  end
end
