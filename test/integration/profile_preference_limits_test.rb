require "test_helper"
require_relative "../support/marketplace_test_factory"

class ProfilePreferenceLimitsTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  test "an unverified account cannot persist oversized profile values or partial account changes" do
    account = create_marketplace_account(prefix: "bounded-pending", verified: false, email_verified: false)
    sign_in_as(account.user)
    original_name = account.user.first_name
    original_preferences = account.profile.attributes.slice("court_preferences", "practice_areas")

    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs do
        patch settings_path(locale: :en), params: {
          account: { first_name: "Partial change" },
          profile: { court_preferences: [ "X" * 65_536 ], practice_areas: (1..301).map { |i| "area-#{i}" } }
        }, as: :json
      end
    end
    assert_response :unprocessable_content
    assert_equal original_name, account.user.reload.first_name
    assert_equal original_preferences, account.profile.reload.attributes.slice("court_preferences", "practice_areas")
    assert_not account.user.marketplace_verified?
    assert_includes response.body, I18n.t("errors.messages.too_many_preferences", count: 50, locale: :en)
  end
end
