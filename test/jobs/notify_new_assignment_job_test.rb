require "test_helper"
require_relative "../support/marketplace_test_factory"

class NotifyNewAssignmentJobTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  setup do
    @owner = subscriber("posting-lawyer")
    @recipient = subscriber("interested-lawyer")
    ActionMailer::Base.deliveries.clear
  end

  teardown { ActionMailer::Base.deliveries.clear }

  test "a posted assignment alerts only eligible subscribers outside the posting workspace, once" do
    colleague = subscriber("colleague")
    colleague.user.memberships.create!(firm: @owner.firm, role: "member")
    create_marketplace_account(prefix: "not-subscribed").user.update!(new_assignment_alerts: false)
    subscriber("unverified", email_verified: false)
    subscriber("pending", verified: false)
    subscriber("admin", system_role: "admin")
    subscriber("suspended").user.update!(suspended_at: Time.current)

    assignment = nil
    assert_enqueued_jobs 1, only: NotifyNewAssignmentJob do
      assignment = create_assignment_for(@owner)
    end

    assert_difference "Notification.count", 1 do
      assert_enqueued_jobs 1, only: NotificationEmailDeliveryJob do
        2.times { NotifyNewAssignmentJob.perform_now(assignment.id) }
      end
    end

    event = Notification.find_by!(kind: "new_assignment", subject: assignment)
    assert_equal @recipient.user.id, event.user_id
    assert_equal "pending", event.email_status
    assert_not_predicate assignment.reload, :new_assignment_alerts_pending?
  end

  test "the email reconciler recovers missed fanout and clears closed alerts" do
    assignment = create_assignment_for(@owner)
    closed = create_assignment_for(@owner)
    closed.cancel!(actor: @owner.user)
    existing = create_assignment_for(@owner, status: "draft")
    existing.update!(status: "open")
    assert_not_predicate existing.reload, :new_assignment_alerts_pending?
    clear_enqueued_jobs

    assert_enqueued_with(job: NotifyNewAssignmentJob, args: [ assignment.id ]) do
      assert_enqueued_with(job: NotifyNewAssignmentJob, args: [ closed.id ]) { ReconcileNotificationEmailsJob.perform_now }
    end
    assert_enqueued_jobs 2, only: NotifyNewAssignmentJob

    assert_difference "Notification.count", 1 do
      perform_enqueued_jobs(only: NotifyNewAssignmentJob)
    end
    assert_not_predicate assignment.reload, :new_assignment_alerts_pending?
    assert_not_predicate closed.reload, :new_assignment_alerts_pending?
    assert_equal assignment, @recipient.user.notifications.find_by!(kind: "new_assignment").subject
  end

  test "new assignment email is localized and omits assignment and sender details" do
    assignment = create_assignment_for(@owner, title: "Sensitive synthetic assignment title")
    NotifyNewAssignmentJob.perform_now(assignment.id)
    event = @recipient.user.notifications.find_by!(kind: "new_assignment", subject: assignment)

    assert_difference(-> { ActionMailer::Base.deliveries.size }, 1) { NotificationEmailDeliveryJob.perform_now(event.id) }

    email = ActionMailer::Base.deliveries.last
    assert_equal "sent", event.reload.email_status
    assert_equal [ @recipient.user.email_address ], email.to
    assert_nil email.bcc
    assert_equal I18n.t("workflow.mailers.new_assignment.subject", locale: :nl), email.subject
    [ email.subject, email.text_part.body.decoded, email.html_part.body.decoded ].each do |value|
      [ assignment.title, assignment.description, assignment.court, assignment.city, @owner.user.email_address ].each do |private_detail|
        assert_not_includes value, private_detail
      end
    end
    [ email.text_part, email.html_part ].each do |part|
      assert_includes part.body.decoded, "/nl/assignments/#{assignment.id}"
      assert_includes part.body.decoded, "/nl/settings#email-notifications"
    end
  end

  test "queued email respects a later opt-out and a closed assignment" do
    assignment = create_assignment_for(@owner)
    NotifyNewAssignmentJob.perform_now(assignment.id)
    event = @recipient.user.notifications.find_by!(kind: "new_assignment", subject: assignment)

    @recipient.user.update!(new_assignment_alerts: false)
    assert_no_difference(-> { ActionMailer::Base.deliveries.size }) { NotificationEmailDeliveryJob.perform_now(event.id) }
    assert_equal "email_preference_disabled", event.reload.email_status_reason

    @recipient.user.update!(new_assignment_alerts: true)
    event.update!(email_status: "pending")
    assignment.cancel!(actor: @owner.user)
    assert_no_difference(-> { ActionMailer::Base.deliveries.size }) { NotificationEmailDeliveryJob.perform_now(event.id) }
    assert_equal "assignment_unavailable", event.reload.email_status_reason
  end

  private

  def subscriber(prefix, **options)
    account = create_marketplace_account(prefix:, **options)
    account.user.update!(new_assignment_alerts: true, locale: "nl")
    account
  end
end
