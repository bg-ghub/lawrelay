require "test_helper"
require_relative "../support/marketplace_test_factory"

class HomeControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "real assignment details stay hidden until the member completes two factor authentication" do
    account = create_marketplace_account(prefix: "home-mfa")
    assignment = create_assignment_for(account, title: "Private hearing behind the second factor")
    assignment.update!(urgent: true, starts_at: 1.hour.from_now, response_deadline_at: 30.minutes.from_now)
    secret = account.user.begin_two_factor_setup!(password: "password1234")
    recovery_codes = account.user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_in_as(account.user)

    %w[nl fr de en].each do |locale|
      get root_path(locale: locale)
      assert_response :success
      assert_not_includes response.body, assignment.title
      assert_select "a.opportunity-card", count: 0
    end

    post verify_two_factor_authentication_path(locale: :en), params: { recovery_code: recovery_codes.first }
    assert_redirected_to dashboard_path(locale: :en)
    get root_path(locale: :en)
    assert_response :success
    assert_includes response.body, assignment.title
  end

  test "verified members without two factor authentication retain featured assignments" do
    account = create_marketplace_account(prefix: "home-no-mfa")
    assignment = create_assignment_for(account, title: "Featured verified member assignment")
    assignment.update!(urgent: true, starts_at: 1.hour.from_now, response_deadline_at: 30.minutes.from_now)
    sign_in_as(account.user)

    get root_path(locale: :en)
    assert_response :success
    assert_includes response.body, assignment.title
  end
end
