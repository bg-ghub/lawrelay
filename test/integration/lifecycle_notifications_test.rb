require "test_helper"
require_relative "../support/marketplace_test_factory"

class LifecycleNotificationsTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "lifecycleowner")
    @candidate = create_marketplace_account(prefix: "lifecyclecandidate")
    @other = create_marketplace_account(prefix: "lifecycleother")
    @assignment = create_assignment_for(@owner)
  end

  test "selection notifies the winner and every pending loser once" do
    winner = create_proposal_for(@assignment, @candidate)
    loser = create_proposal_for(@assignment, @other)
    withdrawn_account = create_marketplace_account(prefix: "lifecyclewithdrawn")
    withdrawn = create_proposal_for(@assignment, withdrawn_account)
    withdrawn.withdraw!(actor: withdrawn_account.user)
    sign_in_as(@owner.user)

    assert_difference("Notification.count", 2) do
      patch accept_assignment_proposal_path(@assignment, winner, locale: :en)
    end
    assert_redirected_to assignment_path(@assignment, locale: :en)
    assert_equal "accepted", winner.reload.status
    assert_equal "declined", loser.reload.status
    assert_equal "withdrawn", withdrawn.reload.status
    assert_equal 1, Notification.where(user: @candidate.user, kind: "proposal_accepted", subject: winner).count
    assert_equal 1, Notification.where(user: @other.user, kind: "proposal_declined", subject: loser).count
    assert_equal 0, Notification.where(user: withdrawn_account.user, kind: "proposal_declined").count
    assert_no_difference([ "Notification.count", "AuditEvent.count" ]) do
      patch accept_assignment_proposal_path(@assignment, winner, locale: :en)
    end
  end

  test "a firm administrator acting for the creator triggers creator and participant notifications" do
    winner = create_proposal_for(@assignment, @candidate)
    manager = create_marketplace_account(prefix: "lifecyclemanager").user
    manager.memberships.create!(firm: @owner.firm, role: "admin")
    sign_in_as(manager)

    patch accept_assignment_proposal_path(@assignment, winner, locale: :en)
    assert_equal 1, @owner.user.notifications.where(kind: "assignment_matched").count
    assert_equal 0, manager.notifications.count

    patch complete_assignment_path(@assignment, locale: :en)
    assert_equal "completed", @assignment.reload.status
    assert_equal [ @owner.user.id, @candidate.user.id ].sort,
      Notification.where(kind: "assignment_completed", subject: @assignment).pluck(:user_id).sort
  end

  test "withdrawal informs the owner but cancellation excludes withdrawn and declined candidates" do
    pending = create_proposal_for(@assignment, @candidate)
    withdrawn = create_proposal_for(@assignment, @other)
    declined_account = create_marketplace_account(prefix: "lifecycledeclined")
    declined = create_proposal_for(@assignment, declined_account)
    declined.decline!(actor: @owner.user)
    sign_in_as(@other.user)
    patch withdraw_assignment_proposal_path(@assignment, withdrawn, locale: :en)
    assert_equal 1, @owner.user.notifications.where(kind: "proposal_withdrawn", subject: withdrawn).count
    assert_equal 0, @other.user.notifications.where(kind: "proposal_withdrawn").count

    sign_in_as(@owner.user)
    patch cancel_assignment_path(@assignment, locale: :en)
    assert_equal "cancelled", @assignment.reload.status
    assert_equal [ @candidate.user.id ], Notification.where(kind: "assignment_cancelled", subject: @assignment).pluck(:user_id)
    assert_equal "pending", pending.reload.status
    assert_no_difference "Notification.count" do
      patch cancel_assignment_path(@assignment, locale: :en)
    end
  end

  test "deadline closure alerts only the owner and still allows a later selection" do
    proposal = create_proposal_for(@assignment, @candidate)
    travel_to @assignment.response_deadline_at + 1.second do
      2.times { ExpireStaleAssignmentsJob.perform_now }
      assert_equal "open", @assignment.reload.status
      assert_equal 1, @owner.user.notifications.where(kind: "response_deadline_closed").count
      assert_equal 0, @candidate.user.notifications.where(kind: "response_deadline_closed").count
      sign_in_as(@owner.user)
      patch accept_assignment_proposal_path(@assignment, proposal, locale: :en)
      assert_equal "matched", @assignment.reload.status
    end
  end

  test "execution expiry informs owner and pending candidates once without retroactive decline" do
    proposal = create_proposal_for(@assignment, @candidate)
    withdrawn = create_proposal_for(@assignment, @other)
    withdrawn.withdraw!(actor: @other.user)
    travel_to @assignment.starts_at, with_usec: true do
      2.times { ExpireStaleAssignmentsJob.perform_now }
      assert_equal "expired", @assignment.reload.status
      assert_equal [ @owner.user.id, @candidate.user.id ].sort,
        Notification.where(kind: "assignment_expired", subject: @assignment).pluck(:user_id).sort
      assert_equal "pending", proposal.reload.status
    end
  end

  test "a failed audit rolls back the notification outbox with the assignment change" do
    proposal = create_proposal_for(@assignment, @candidate)
    @assignment.update!(status: "matched")
    proposal.update!(status: "accepted")
    callback = -> { raise "Synthetic audit failure" }
    AuditEvent.set_callback(:create, :before, callback)
    assert_no_difference "Notification.count" do
      assert_raises(RuntimeError) { @assignment.complete!(actor: @owner.user) }
    end
    assert_equal "matched", @assignment.reload.status
  ensure
    AuditEvent.skip_callback(:create, :before, callback) if callback
  end
end
