require "test_helper"
require_relative "../support/marketplace_test_factory"

class ExpireStaleAssignmentsJobTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  test "expires only overdue open assignments and records one durable outcome" do
    owner = create_marketplace_account(prefix: "expiry-owner")
    stale = create_assignment_for(owner, title: "Stale assignment")
    matched = create_assignment_for(owner, title: "Matched assignment", status: "matched")
    upcoming = create_assignment_for(owner, title: "Upcoming assignment")

    overdue_start = 1.minute.ago
    overdue_response_deadline = overdue_start - 1.hour
    stale.update!(starts_at: overdue_start, response_deadline_at: overdue_response_deadline)
    matched.update!(starts_at: overdue_start, response_deadline_at: overdue_response_deadline)

    assert_difference(-> { AuditEvent.where(action: "assignment.expired").count }, 1) do
      assert_difference(-> { Notification.where(kind: "assignment_expired").count }, 1) do
        ExpireStaleAssignmentsJob.perform_now
      end
    end

    assert_equal "expired", stale.reload.status
    assert_equal "matched", matched.reload.status
    assert_equal "open", upcoming.reload.status

    notification = owner.user.notifications.find_by!(kind: "assignment_expired")
    assert_equal stale, notification.subject
    assert_equal stale.id, notification.data.fetch("assignment_id")

    assert_no_difference(-> { Notification.where(kind: "assignment_expired").count }) do
      ExpireStaleAssignmentsJob.perform_now
    end
  end
end
