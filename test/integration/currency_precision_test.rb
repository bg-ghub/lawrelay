require "test_helper"
require_relative "../support/marketplace_test_factory"

class CurrencyPrecisionTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "fractional euros survive proposal validation and render in each locale" do
    owner = create_marketplace_account(prefix: "decimalowner")
    candidate = create_marketplace_account(prefix: "decimalcandidate")
    assignment = create_assignment_for(owner)
    assignment.update!(fee_cents: 25_055)
    sign_in_as(candidate.user)

    %w[nl fr de en].each do |locale|
      get assignment_path(assignment, locale:)
      assert_response :success
      assert_select ".proposal-panel__price strong", text: locale == "en" ? "€ 250.55" : "€ 250,55"
      assert_select "input[name='proposal[rate_cents]'][value='250.55'][step='0.01']"

      post assignment_proposals_path(assignment, locale:), params: {
        proposal: { rate_cents: "275.65", message: "" }
      }
      assert_response :unprocessable_content
      assert_select "input[name='proposal[rate_cents]'][value='275.65']"
    end

    proposal = create_proposal_for(assignment, candidate, rate_cents: 27_565)
    get dashboard_path(locale: :en)
    assert_select ".proposal-preview p", text: /275\.65/
    sign_in_as(owner.user)
    get assignment_path(assignment, locale: :nl)
    assert_select ".candidate-proposal strong", text: "€ 275,65"
    assert_equal 27_565, proposal.reload.rate_cents
  end

  test "an assignment form preserves cents and zero after another field fails validation" do
    owner = create_marketplace_account(prefix: "decimalposting")
    sign_in_as(owner.user)

    %w[250.55 0].each do |amount|
      assert_no_difference "Assignment.count" do
        post assignments_path(locale: :nl), params: {
          assignment: {
            title: "", kind: "court_replacement", fee_cents: amount,
            starts_at: 3.days.from_now, response_deadline_at: 2.days.from_now,
            content_rules_accepted: "1"
          }
        }
      end
      assert_response :unprocessable_content
      assert_select "input[name='assignment[fee_cents]'][value='#{amount}'][step='0.01']"
    end
  end
end
