require "test_helper"
require_relative "../support/marketplace_test_factory"

class AnalyticsPrivacyBoundaryTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "analytics is absent outside production even when a website ID exists" do
    previous_website_id = ENV["UMAMI_WEBSITE_ID"]
    ENV["UMAMI_WEBSITE_ID"] = "test-website-id"

    get privacy_path(locale: :en)
    assert_response :success
    assert_select "body[data-lawrelay-analytics-website-id]", count: 0
  ensure
    previous_website_id ? ENV["UMAMI_WEBSITE_ID"] = previous_website_id : ENV.delete("UMAMI_WEBSITE_ID")
  end

  test "authenticated pages never render analytics configuration" do
    account = create_marketplace_account(prefix: "analytics-private")
    sign_in_as(account.user)

    get settings_path(locale: :en)
    assert_response :success
    assert_select "body[data-lawrelay-analytics-website-id]", count: 0
  end
end
