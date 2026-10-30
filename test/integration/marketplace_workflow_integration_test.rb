require "test_helper"
require_relative "../support/marketplace_test_factory"

class MarketplaceWorkflowIntegrationTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "creating an assignment records ownership, audit event, and locale-preserving redirect" do
    owner = create_marketplace_account(prefix: "creator")
    sign_in_as(owner.user)

    assert_difference([ "Assignment.count", "AuditEvent.count" ], 1) do
      post "/de/assignments", params: {
        assignment: {
          kind: "court_replacement",
          title: "Locale-owned assignment",
          description: "A safe description without confidential matter information.",
          city: "Eupen",
          court: "Gericht",
          starts_at: 3.days.from_now,
          duration_minutes: 60,
          practice_area: "Commercial law",
          fee_cents: "300",
          content_rules_accepted: "1"
        }.merge(invoice_recipient_attributes)
      }
    end

    assignment = Assignment.order(:id).last
    assert_redirected_to "/de/assignments/#{assignment.id}"
    assert_equal owner.user, assignment.creator_user
    assert_equal owner.firm, assignment.firm
    assert_equal "assignment.created", assignment.audit_events.last.action
  end

  test "a legal task can be posted remotely with structured deadlines" do
    owner = create_marketplace_account(prefix: "remotelegal")
    sign_in_as(owner.user)

    post "/en/assignments", params: {
      assignment: {
        kind: "legal_task",
        assignment_subtype: "contract",
        title: "Review a short commercial contract",
        description: "A bounded review without client-identifying information.",
        practice_area: "Commercial law",
        languages: "EN / NL",
        scope_indication: "Review of a short draft",
        response_deadline_at: 2.days.from_now,
        delivery_due_at: 3.days.from_now,
        starts_at: 4.days.from_now,
        fee_cents: "350",
        content_rules_accepted: "1"
      }.merge(invoice_recipient_attributes)
    }

    assignment = Assignment.order(:id).last
    assert_redirected_to "/en/assignments/#{assignment.id}"
    assert assignment.legal_task?
    assert_nil assignment.court
    assert_nil assignment.city
    assert_equal "contract", assignment.assignment_subtype
    assert_equal "Review of a short draft", assignment.scope_indication
  end

  test "proposal creation records actor, audit event, and owner notification" do
    owner = create_marketplace_account(prefix: "proposalowner")
    candidate = create_marketplace_account(prefix: "proposercandidate")
    assignment = create_assignment_for(owner)
    sign_in_as(candidate.user)

    assert_difference("Proposal.count", 1) do
      assert_difference("AuditEvent.count", 1) do
        assert_difference("Notification.count", 1) do
          post "/fr/assignments/#{assignment.id}/proposals", params: {
            proposal: { rate_cents: "275", message: "Je suis disponible pour cette audience." }
          }
        end
      end
    end

    proposal = Proposal.order(:id).last
    assert_redirected_to "/fr/assignments/#{assignment.id}"
    assert_equal candidate.user, proposal.user
    assert_equal candidate.firm, proposal.firm
    assert_equal owner.user, Notification.order(:id).last.user
    assert_equal "new_proposal", Notification.order(:id).last.kind
  end

  test "owner acceptance selects one proposal, declines others, and records audit and notification" do
    owner = create_marketplace_account(prefix: "acceptowner")
    accepted_candidate = create_marketplace_account(prefix: "acceptedcandidate")
    other_candidate = create_marketplace_account(prefix: "othercandidate")
    assignment = create_assignment_for(owner)
    accepted_proposal = create_proposal_for(assignment, accepted_candidate)
    other_proposal = create_proposal_for(assignment, other_candidate)
    sign_in_as(owner.user)

    assert_difference("AuditEvent.count", 3) do
      assert_difference("Notification.count", 2) do
        patch "/nl/assignments/#{assignment.id}/proposals/#{accepted_proposal.id}/accept"
      end
    end

    assert_redirected_to "/nl/assignments/#{assignment.id}"
    assert_equal "matched", assignment.reload.status
    assert_equal "accepted", accepted_proposal.reload.status
    assert_not_nil accepted_proposal.accepted_at
    assert_equal "declined", other_proposal.reload.status
    assert_not_nil other_proposal.declined_at
    assert_equal accepted_proposal, assignment.accepted_proposal
    assert_equal "proposal_accepted", accepted_candidate.user.notifications.last.kind
    assert_equal "proposal_declined", other_candidate.user.notifications.last.kind
  end

  test "owner can decline a pending proposal and candidate is notified" do
    owner = create_marketplace_account(prefix: "declineowner")
    candidate = create_marketplace_account(prefix: "declinecandidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(owner.user)

    assert_difference([ "AuditEvent.count", "Notification.count" ], 1) do
      patch "/en/assignments/#{assignment.id}/proposals/#{proposal.id}/decline"
    end

    assert_redirected_to "/en/assignments/#{assignment.id}"
    assert_equal "declined", proposal.reload.status
    assert_not_nil proposal.declined_at
    assert_equal "proposal_declined", candidate.user.notifications.last.kind
  end

  test "proposer can withdraw their own pending proposal" do
    owner = create_marketplace_account(prefix: "withdrawowner")
    candidate = create_marketplace_account(prefix: "withdrawcandidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(candidate.user)

    assert_difference("AuditEvent.count", 1) do
      patch "/en/assignments/#{assignment.id}/proposals/#{proposal.id}/withdraw"
    end

    assert_redirected_to "/en/assignments/#{assignment.id}"
    assert_equal "withdrawn", proposal.reload.status
    assert_not_nil proposal.withdrawn_at
  end

  test "another candidate cannot withdraw someone else's proposal" do
    owner = create_marketplace_account(prefix: "protectedowner")
    candidate = create_marketplace_account(prefix: "protectedcandidate")
    outsider = create_marketplace_account(prefix: "protectedoutsider")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(outsider.user)

    assert_no_difference("AuditEvent.count") do
      patch "/en/assignments/#{assignment.id}/proposals/#{proposal.id}/withdraw"
    end

    assert_redirected_to "/en/assignments/#{assignment.id}"
    assert_equal "pending", proposal.reload.status
  end
end
