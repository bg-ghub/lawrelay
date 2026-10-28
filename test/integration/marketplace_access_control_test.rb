require "test_helper"
require_relative "../support/marketplace_test_factory"

class MarketplaceAccessControlTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "anonymous marketplace access redirects to a locale-preserving login" do
    get "/fr/assignments"

    assert_redirected_to "/fr/session/new"
  end

  test "pending lawyer is redirected to locale-preserving verification status" do
    pending_account = create_marketplace_account(prefix: "pending", verified: false)
    sign_in_as(pending_account.user)

    get "/de/assignments"

    assert_redirected_to "/de/verification_status"
  end

  test "verified lawyer can access the assignment board" do
    verified_account = create_marketplace_account(prefix: "verified")
    sign_in_as(verified_account.user)

    get "/en/assignments"

    assert_response :success
  end

  test "dashboard is scoped to the signed-in firm" do
    signed_in_account = create_marketplace_account(prefix: "dashboard")
    other_account = create_marketplace_account(prefix: "other")
    own_assignment = create_assignment_for(signed_in_account, title: "Visible firm assignment")
    create_assignment_for(other_account, title: "Other firm's private dashboard item")
    sign_in_as(signed_in_account.user)

    get "/en/dashboard"

    assert_response :success
    assert_includes response.body, own_assignment.title
    assert_not_includes response.body, "Other firm's private dashboard item"
  end

  test "non-owner cannot cancel another firm's assignment" do
    owner = create_marketplace_account(prefix: "owner")
    outsider = create_marketplace_account(prefix: "outsider")
    assignment = create_assignment_for(owner)
    sign_in_as(outsider.user)

    assert_no_difference("AuditEvent.count") do
      patch "/en/assignments/#{assignment.id}/cancel"
    end

    assert_redirected_to "/en/assignments"
    assert_equal "open", assignment.reload.status
  end

  test "lawyer cannot propose to an assignment from the same firm" do
    owner = create_marketplace_account(prefix: "samefirm")
    colleague = User.create!(
      email_address: "colleague-#{SecureRandom.hex(4)}@example.test",
      password: "password1234",
      first_name: "Firm",
      last_name: "Colleague",
      locale: "en",
      email_verified_at: Time.current
    )
    colleague.memberships.create!(firm: owner.firm, role: "member")
    colleague.create_lawyer_profile!(
      bar_association: "OVB",
      bar_number: "COLLEAGUE-#{SecureRandom.hex(4)}",
      verification_status: "verified",
      verified_at: Time.current
    )
    assignment = create_assignment_for(owner)
    sign_in_as(colleague)

    assert_no_difference("Proposal.count") do
      post "/en/assignments/#{assignment.id}/proposals", params: {
        proposal: { rate_cents: "250", message: "I can cover this hearing." }
      }
    end

    assert_redirected_to "/en/assignments/#{assignment.id}"
  end

  test "ordinary firm member cannot mutate a colleague's assignment" do
    owner = create_marketplace_account(prefix: "managerowner")
    colleague = User.create!(
      email_address: "manager-colleague-#{SecureRandom.hex(4)}@example.test",
      password: "password1234",
      first_name: "Firm",
      last_name: "Member",
      locale: "en",
      email_verified_at: Time.current
    )
    colleague.memberships.create!(firm: owner.firm, role: "member")
    colleague.create_lawyer_profile!(
      bar_association: "OVB",
      bar_number: "MANAGER-#{SecureRandom.hex(4)}",
      verification_status: "verified",
      verified_at: Time.current
    )
    assignment = create_assignment_for(owner)
    sign_in_as(colleague)

    patch "/en/assignments/#{assignment.id}/cancel"

    assert_redirected_to "/en/assignments"
    assert_equal "open", assignment.reload.status
  end

  test "unrelated lawyer cannot open a closed assignment by guessing its id" do
    owner = create_marketplace_account(prefix: "closedowner")
    outsider = create_marketplace_account(prefix: "closedoutsider")
    assignment = create_assignment_for(owner, status: "completed")
    sign_in_as(outsider.user)

    get "/en/assignments/#{assignment.id}"

    assert_redirected_to "/en/assignments"
    assert_not_includes response.body, assignment.description
  end

  test "a proposer cannot see another candidate's identity or message" do
    owner = create_marketplace_account(prefix: "privacyowner")
    first_candidate = create_marketplace_account(prefix: "firstcandidate")
    second_candidate = create_marketplace_account(prefix: "secondcandidate")
    assignment = create_assignment_for(owner)
    create_proposal_for(assignment, first_candidate, message: "First private proposal")
    create_proposal_for(assignment, second_candidate, message: "Second private proposal")
    sign_in_as(first_candidate.user)

    get "/en/assignments/#{assignment.id}"

    assert_response :success
    assert_includes response.body, "First private proposal"
    assert_not_includes response.body, second_candidate.user.full_name
    assert_not_includes response.body, second_candidate.user.email_address
    assert_not_includes response.body, "Second private proposal"
  end
end
