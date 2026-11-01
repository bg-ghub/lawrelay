require "test_helper"
require_relative "../../support/marketplace_test_factory"

class NotificationsRecoverSkippedEmailsTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "recover-owner")
    @candidate = create_marketplace_account(prefix: "recover-candidate")
    @assignment = create_assignment_for(@owner)
    @proposal = create_proposal_for(@assignment, @candidate)
    @proposal.update!(status: "accepted", accepted_at: Time.current)
    @assignment.update!(status: "matched")
    @event = Notification.publish!(user: @candidate.user, kind: "proposal_accepted", subject: @proposal, assignment: @assignment)
    @event.update!(email_status: "skipped", email_status_reason: "unverified_recipient", email_attempts: 1)
    clear_enqueued_jobs
    ActionMailer::Base.deliveries.clear
  end

  teardown { ActionMailer::Base.deliveries.clear }

  test "dry run reviews only eligible rows and changes nothing" do
    original = @event.attributes

    assert_no_difference("AuditEvent.count") do
      assert_no_enqueued_jobs do
        result = Notifications::RecoverSkippedEmails.new.call
        assert result.dry_run
        assert_equal [ @event.id ], result.notification_ids
      end
    end

    assert_equal original, @event.reload.attributes
  end

  test "repair is idempotent and uses normal delivery without duplicates" do
    assert_difference("AuditEvent.where(action: 'notification.email_recovered').count", 1) do
      result = Notifications::RecoverSkippedEmails.new(dry_run: false).call
      assert_not result.dry_run
      assert_equal [ @event.id ], result.notification_ids
      assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
    end
    assert_equal "pending", @event.reload.email_status
    assert_equal 0, @event.email_attempts
    assert_nil @event.email_status_reason

    ReconcileNotificationEmailsJob.perform_now
    assert_difference(-> { ActionMailer::Base.deliveries.size }, 1) do
      perform_enqueued_jobs only: NotificationEmailDeliveryJob
      NotificationEmailDeliveryJob.perform_now(@event.id)
    end
    assert_equal "sent", @event.reload.email_status
  end

  test "old future and already-sent rows are excluded" do
    [ { created_at: 25.hours.ago }, { created_at: 1.hour.from_now }, { email_sent_at: Time.current } ].each do |changes|
      original = @event.attributes.slice(*changes.keys.map(&:to_s))
      @event.update_columns(changes)
      assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
      @event.update_columns(original)
    end
    assert_equal "skipped", @event.reload.email_status
  end

  test "other skip reasons and delivery outcomes are not replayed" do
    [ { email_status_reason: "inactive_recipient" }, { email_status: "sent" }, { email_status: "failed" } ].each do |changes|
      original = @event.attributes.slice(*changes.keys.map(&:to_s))
      @event.update_columns(changes)
      assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
      @event.update_columns(original)
    end
  end

  test "current account eligibility and event state must still permit delivery" do
    @candidate.user.update!(email_verified_at: nil)
    assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
    @candidate.user.update!(email_verified_at: Time.current)
    @candidate.profile.update!(verification_status: "suspended")
    assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
    @candidate.profile.update!(verification_status: "verified")
    @assignment.update!(status: "cancelled")
    assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
  end

  test "an acceptance after the hearing time is not recovered" do
    @assignment.update_columns(starts_at: 1.minute.ago)

    assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
    assert_equal "skipped", @event.reload.email_status
  end

  test "a decline from work that has since been cancelled is not recovered" do
    @proposal.update!(status: "declined")
    @assignment.update!(status: "cancelled")
    @event.update!(kind: "proposal_declined")

    assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
    assert_equal "skipped", @event.reload.email_status
  end

  test "a changed record is checked again after its row is locked" do
    original = Notification.instance_method(:with_lock)
    target_id = @event.id
    Notification.define_method(:with_lock) do |*arguments, &block|
      update_columns(email_sent_at: Time.current) if id == target_id
      original.bind_call(self, *arguments, &block)
    end

    assert_empty Notifications::RecoverSkippedEmails.new(dry_run: false).call.notification_ids
    assert_equal "skipped", @event.reload.email_status
  ensure
    Notification.define_method(:with_lock, original) if original
  end
end
