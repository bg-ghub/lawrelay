require "test_helper"
require_relative "../support/marketplace_test_factory"

class NotificationOutboxTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "outboxowner")
    @candidate = create_marketplace_account(prefix: "outboxcandidate")
    @assignment = create_assignment_for(@owner)
  end

  test "events are idempotent per recipient and legacy notifications are never mailed" do
    legacy = @owner.user.notifications.create!(kind: "new_proposal", subject: @assignment, created_at: 1.month.ago)
    assert_nil legacy.email_status
    clear_enqueued_jobs

    assert_enqueued_with(job: NotificationEmailDeliveryJob) do
      @event = publish
    end
    assert_equal "pending", @event.email_status
    assert_equal @assignment.id, @event.data.fetch("assignment_id")
    assert_no_difference "Notification.count" do
      assert_no_enqueued_jobs { assert_equal @event, publish }
    end

    clear_enqueued_jobs
    assert_enqueued_with(job: NotificationEmailDeliveryJob, args: [ @event.id ]) do
      ReconcileNotificationEmailsJob.perform_now
    end
    assert_nil legacy.reload.email_status
  end

  test "rolling back the business operation rolls back events and queue callbacks" do
    assert_no_difference "Notification.count" do
      assert_no_enqueued_jobs do
        ApplicationRecord.transaction do
          publish
          raise ActiveRecord::Rollback
        end
      end
    end
  end

  test "a missing queue enqueue is recovered from the committed outbox" do
    original = NotificationEmailDeliveryJob.method(:perform_later)
    NotificationEmailDeliveryJob.define_singleton_method(:perform_later) { |*| raise ActiveJob::EnqueueError, "Synthetic queue failure" }
    event = publish
    assert event.persisted?
    assert_equal "pending", event.email_status
    NotificationEmailDeliveryJob.define_singleton_method(:perform_later, original)

    assert_enqueued_with(job: NotificationEmailDeliveryJob, args: [ event.id ]) do
      ReconcileNotificationEmailsJob.perform_now
    end
  ensure
    NotificationEmailDeliveryJob.define_singleton_method(:perform_later, original) if original
  end

  test "only one sender claims a lease and stale claims can be recovered" do
    event = publish
    now = Time.current
    assert event.claim_email_delivery!(now:)
    assert_not Notification.find(event.id).claim_email_delivery!(now: now + 1.minute)
    stale_claim = event.email_claimed_at

    replacement = Notification.find(event.id)
    assert replacement.claim_email_delivery!(now: now + Notification::EMAIL_LEASE + 1.second)
    assert_equal 2, replacement.email_attempts
    event.email_claimed_at = stale_claim
    assert_equal 0, event.finish_email_delivery!(status: "sent")
    assert_equal 0, event.fail_email_delivery!(error: IOError.new("Stale worker"))
    assert_not event.current_email_delivery_claim?
    assert_equal "sending", replacement.reload.email_status
    assert_nil replacement.email_status_reason
    assert_nil replacement.email_retry_at
  end

  test "outbox health reports exhausted or late deliveries without historical false alarms" do
    @owner.user.notifications.create!(kind: "new_proposal", created_at: 1.month.ago)
    assert_not Notification.email_delivery_unhealthy?

    event = publish
    assert_not Notification.email_delivery_unhealthy?
    event.update!(created_at: 16.minutes.ago)
    assert Notification.email_delivery_unhealthy?
    event.update!(email_retry_at: 1.minute.from_now)
    assert_not Notification.email_delivery_unhealthy?
    event.update!(email_status: "failed")
    assert Notification.email_delivery_unhealthy?
  end

  private

  def publish
    Notification.publish!(user: @candidate.user, kind: "assignment_expired", subject: @assignment, assignment: @assignment)
  end
end
