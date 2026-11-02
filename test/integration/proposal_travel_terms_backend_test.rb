require "test_helper"
require_relative "../support/marketplace_test_factory"

class ProposalTravelTermsBackendTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @owner = create_marketplace_account(prefix: "traveltermsowner")
    @candidate = create_marketplace_account(prefix: "traveltermscandidate")
    @assignment = create_assignment_for(@owner)
    sign_in_as(@candidate.user)
  end

  test "explicit separate travel costs accept comma decimals as an additional fixed amount" do
    assert_difference("Proposal.count", 1) do
      post assignment_proposals_path(@assignment, locale: :en), params: {
        proposal: proposal_params(travel_included: "false", travel_cost_cents: "12,50")
      }
    end
    assert_redirected_to assignment_path(@assignment, locale: :en)
    proposal = @assignment.proposals.sole
    assert_equal false, proposal.travel_included
    assert_equal 1_250, proposal.travel_cost_cents
    assert_equal "fixed", proposal.travel_cost_kind
    assert_equal 9_050, proposal.rate_cents
  end

  test "per kilometre travel rates retain decimal euros and their kind after selection" do
    assert_difference("Proposal.count", 1) do
      post assignment_proposals_path(@assignment, locale: :en), params: {
        proposal: proposal_params(travel_included: "false", travel_cost_kind: "per_km", travel_cost_cents: "0,45")
      }
    end
    assert_redirected_to assignment_path(@assignment, locale: :en)
    proposal = @assignment.proposals.sole
    assert_equal "per_km", proposal.travel_cost_kind
    assert_equal 45, proposal.travel_cost_cents

    sign_in_as(@owner.user)
    patch accept_assignment_proposal_path(@assignment, proposal, locale: :en)
    assert_redirected_to assignment_path(@assignment, locale: :en)
    assert_equal "accepted", proposal.reload.status
    assert_equal "per_km", proposal.travel_cost_kind
    assert_equal 45, proposal.travel_cost_cents
  end

  test "unknown and blank separate travel kinds cannot create an offer" do
    [ "", "hourly", "per_mile" ].each do |kind|
      assert_no_difference("Proposal.count") do
        post assignment_proposals_path(@assignment, locale: :en), params: {
          proposal: proposal_params(travel_included: "false", travel_cost_kind: kind, travel_cost_cents: "1.00")
        }
      end
      assert_response :unprocessable_content
    end
  end

  test "included travel clears a stale additional amount" do
    post assignment_proposals_path(@assignment, locale: :en), params: {
      proposal: proposal_params(travel_included: "true", travel_cost_cents: "999.99", travel_cost_kind: "per_km")
    }
    assert_redirected_to assignment_path(@assignment, locale: :en)
    proposal = @assignment.proposals.sole
    assert_equal true, proposal.travel_included
    assert_nil proposal.travel_cost_cents
    assert_nil proposal.travel_cost_kind
  end

  test "missing legacy travel fields remain unspecified and do not block selection" do
    post assignment_proposals_path(@assignment, locale: :en), params: { proposal: proposal_params }
    assert_redirected_to assignment_path(@assignment, locale: :en)
    proposal = @assignment.proposals.sole
    assert_nil proposal.travel_included
    assert_nil proposal.travel_cost_cents
    assert_nil proposal.travel_cost_kind

    sign_in_as(@owner.user)
    patch accept_assignment_proposal_path(@assignment, proposal, locale: :en)
    assert_redirected_to assignment_path(@assignment, locale: :en)
    assert_equal "accepted", proposal.reload.status
    assert_equal "matched", @assignment.reload.status
    assert_nil proposal.travel_included
  end

  test "unspecified travel does not retain an unclaimed additional amount" do
    post assignment_proposals_path(@assignment, locale: :en), params: {
      proposal: proposal_params(travel_cost_cents: "25.00")
    }
    assert_redirected_to assignment_path(@assignment, locale: :en)
    proposal = @assignment.proposals.sole
    assert_nil proposal.travel_included
    assert_nil proposal.travel_cost_cents
  end

  test "missing malformed negative and overflowing separate costs cannot create an offer" do
    [ nil, "", "invalid", "NaN", "Infinity", "-0.01", "999999999999999999999999" ].each do |amount|
      assert_no_difference("Proposal.count") do
        post assignment_proposals_path(@assignment, locale: :en), params: {
          proposal: proposal_params(travel_included: "false", travel_cost_cents: amount)
        }
      end
      assert_response :unprocessable_content
    end
  end

  test "zero travel cost is valid but unknown inclusion choices are not" do
    assert_no_difference("Proposal.count") do
      post assignment_proposals_path(@assignment, locale: :en), params: {
        proposal: proposal_params(travel_included: "unknown", travel_cost_cents: "0")
      }
    end
    assert_response :unprocessable_content

    post assignment_proposals_path(@assignment, locale: :en), params: {
      proposal: proposal_params(travel_included: "false", travel_cost_cents: "0")
    }
    assert_redirected_to assignment_path(@assignment, locale: :en)
    assert_equal 0, @assignment.proposals.sole.travel_cost_cents
  end

  test "legal task requests ignore travel parameters" do
    @assignment.update!(kind: "legal_task", assignment_subtype: "advice", languages: "EN", court: nil, city: nil)
    post assignment_proposals_path(@assignment, locale: :en), params: {
      proposal: proposal_params(travel_included: "false", travel_cost_cents: "invalid", travel_cost_kind: "invalid")
    }
    assert_redirected_to assignment_path(@assignment, locale: :en)
    proposal = @assignment.proposals.sole
    assert_nil proposal.travel_included
    assert_nil proposal.travel_cost_cents
    assert_nil proposal.travel_cost_kind
  end

  private

  def proposal_params(**travel)
    { rate_cents: "90.50", rate_kind: "hourly", message: "A fictional court-cover offer.", **travel }
  end
end
