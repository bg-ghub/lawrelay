require "test_helper"

class AnalyticsHelperTest < ActiveSupport::TestCase
  include AnalyticsHelper

  test "only public marketing actions are eligible for Umami" do
    assert umami_analytics_public_action?(controller_path: "home", action_name: "index")
    %w[privacy terms cookie_policy legal_notice court_cover legal_assignments].each do |action|
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

  test "public tracking requires the exact production origin even with a production website ID" do
    context = Object.new.extend(AnalyticsHelper)
    context.define_singleton_method(:admin_host?) { false }
    context.define_singleton_method(:authenticated?) { false }
    context.define_singleton_method(:controller_path) { "home" }
    context.define_singleton_method(:action_name) { "index" }
    context.define_singleton_method(:umami_analytics_configured?) { true }

    origins = {
      "https://lawrelay.be" => true,
      "http://lawrelay.be" => false,
      "https://lawrelay.be:3106" => false,
      "https://www.lawrelay.be" => false,
      "https://admin.lawrelay.be" => false,
      "https://analytics.lawrelay.be" => false,
      "https://lawrelay.be.example.com" => false,
      "http://localhost:3106" => false,
      "http://clicks.qa.localhost:3106" => false,
      "https://qa.lawrelay.test" => false,
      "http://127.0.0.1:3106" => false
    }

    origins.each do |origin, expected|
      request = Struct.new(:base_url, :get?).new(origin, true)
      context.define_singleton_method(:request) { request }
      assert_equal expected, context.umami_analytics_enabled?, origin
    end
  end
end
