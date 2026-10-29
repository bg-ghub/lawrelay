require "test_helper"
require "rake"
require_relative "../../support/marketplace_test_factory"

Rails.application.load_tasks unless Rake::Task.task_defined?("lawrelay:retry_notification_email")

class NotificationTasksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    owner = create_marketplace_account(prefix: "retryowner")
    assignment = create_assignment_for(owner)
    @event = Notification.publish!(user: owner.user, kind: "assignment_expired", subject: assignment, assignment: assignment)
    @event.update!(email_status: "failed", email_attempts: 5, email_status_reason: "IOError")
    clear_enqueued_jobs
  end

  test "a failed event can be retried with an audit record and no immediate delivery" do
    assert_difference("AuditEvent.where(action: 'notification.email_retried').count", 1) do
      assert_enqueued_with(job: NotificationEmailDeliveryJob, args: [ @event.id ]) { invoke(@event.id) }
    end
    assert_equal "pending", @event.reload.email_status
    assert_equal 0, @event.email_attempts
    assert_nil @event.email_status_reason
    assert_nil @event.email_sent_at
    assert_equal "rake", AuditEvent.where(auditable: @event).last.metadata.fetch("source")
  end

  test "pending sent and legacy events cannot be retried" do
    [ "pending", "sent", nil ].each do |status|
      @event.update!(email_status: status)
      assert_no_difference "AuditEvent.count" do
        assert_no_enqueued_jobs { assert_raises(SystemExit) { invoke(@event.id) } }
      end
      status.nil? ? assert_nil(@event.reload.email_status) : assert_equal(status, @event.reload.email_status)
    end
  end

  private

  def invoke(id)
    task = Rake::Task["lawrelay:retry_notification_email"]
    task.reenable
    task.invoke(id.to_s)
  end
end
