require "test_helper"
require_relative "../support/marketplace_test_factory"

class MarketplaceStateConstraintsTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  test "database permits only one accepted proposal per assignment" do
    owner = create_marketplace_account(prefix: "uniqueowner")
    first_candidate = create_marketplace_account(prefix: "uniquefirst")
    second_candidate = create_marketplace_account(prefix: "uniquesecond")
    assignment = create_assignment_for(owner)
    first = create_proposal_for(assignment, first_candidate)
    second = create_proposal_for(assignment, second_candidate)
    first.update!(status: "accepted", accepted_at: Time.current)

    assert_raises(ActiveRecord::RecordNotUnique) do
      second.update_columns(status: "accepted", accepted_at: Time.current)
    end
  end

  test "assignment ownership follows firm membership" do
    owner = create_marketplace_account(prefix: "modelowner")
    colleague = create_marketplace_account(prefix: "modeloutsider")
    assignment = create_assignment_for(owner)

    assert assignment.owned_by?(owner.user)
    assert_not assignment.owned_by?(colleague.user)
    assert_not assignment.owned_by?(nil)
  end

  test "assignment rejects invalid terminal-state transitions" do
    owner = create_marketplace_account(prefix: "terminalowner")
    assignment = create_assignment_for(owner, status: "completed")

    assert_raises(Assignment::InvalidTransition) { assignment.cancel!(actor: owner.user) }
    assert_equal "completed", assignment.reload.status
  end

  test "only pending proposals can be withdrawn or declined" do
    owner = create_marketplace_account(prefix: "proposalstateowner")
    candidate = create_marketplace_account(prefix: "proposalstatecandidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    proposal.update!(status: "accepted", accepted_at: Time.current)

    assert_raises(Proposal::InvalidTransition) { proposal.withdraw!(actor: candidate.user) }
    assert_raises(Proposal::InvalidTransition) { proposal.decline!(actor: owner.user) }
    assert_equal "accepted", proposal.reload.status
  end
end
