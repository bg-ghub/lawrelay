require "test_helper"
require_relative "../support/marketplace_test_factory"

class NotificationEmailDeliveryJobTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "deliveryowner")
    @candidate = create_marketplace_account(prefix: "deliverycandidate")
    @assignment = create_assignment_for(@owner)
    @proposal = create_proposal_for(@assignment, @candidate)
    @proposal.update!(status: "accepted", accepted_at: Time.current)
    @assignment.update!(status: "matched")
    @event = Notification.publish!(user: @candidate.user, kind: "proposal_accepted", subject: @proposal, assignment: @assignment)
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
  end

  teardown { ActionMailer::Base.deliveries.clear }

  test "a persisted event delivers once in the recipient language with a stable message id" do
    @candidate.user.update!(locale: "fr")
    assert_difference(-> { ActionMailer::Base.deliveries.length }, 1) do
      NotificationEmailDeliveryJob.perform_now(@event.id)
      NotificationEmailDeliveryJob.perform_now(@event.id)
    end
    assert_equal "sent", @event.reload.email_status
    assert @event.email_sent_at
    assert_equal 1, @event.email_attempts
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ @candidate.user.email_address ], mail.to
    assert_equal I18n.t("workflow.mailers.proposal_accepted.subject", locale: :fr, title: @assignment.title), mail.subject
    assert_match(/\Anotification-#{@event.id}@/, mail.message_id)
    assert_nil mail.bcc
  end

  test "delivery failures keep a durable retry without storing the error message" do
    captured_message_id = nil
    with_delivery_failure do |message|
      error = assert_raises(IOError) { NotificationEmailDeliveryJob.new.perform(@event.id) }
      assert_equal "Sensitive synthetic SMTP details", error.message
      captured_message_id = message.message_id
    end

    assert_equal "pending", @event.reload.email_status
    assert_equal "IOError", @event.email_status_reason
    assert_equal 1, @event.email_attempts
    assert @event.email_retry_at > Time.current
    assert_not_includes @event.attributes.to_json, "Sensitive synthetic SMTP details"

    retry_at = @event.email_retry_at
    travel_to retry_at + 1.second do
      assert_difference(-> { ActionMailer::Base.deliveries.length }, 1) do
        NotificationEmailDeliveryJob.perform_now(@event.id)
      end
    end
    assert_equal "sent", @event.reload.email_status
    assert_equal captured_message_id, ActionMailer::Base.deliveries.last.message_id
  end

  test "exhausted delivery attempts are visible to operational health and stop retrying" do
    with_delivery_failure do
      Notification::MAX_EMAIL_ATTEMPTS.times do
        assert_raises(IOError) { NotificationEmailDeliveryJob.new.perform(@event.id) }
        @event.reload
        travel_to @event.email_retry_at + 1.second if @event.email_retry_at
      end
    end
    assert_equal "failed", @event.reload.email_status
    assert_equal Notification::MAX_EMAIL_ATTEMPTS, @event.email_attempts
    assert Notification.email_delivery_unhealthy?
    clear_enqueued_jobs
    ReconcileNotificationEmailsJob.perform_now
    assert_not enqueued_jobs.any? { |job| job[:job] == NotificationEmailDeliveryJob && job[:args] == [ @event.id ] }
  ensure
    travel_back
  end

  test "inactive unverified and administrator recipients are recorded as skipped rather than delivered" do
    [ [ { suspended_at: Time.current }, "inactive_recipient" ],
      [ { email_verified_at: nil }, "unverified_recipient" ],
      [ { system_role: "admin" }, "administrator_recipient" ] ].each do |attributes, expected_reason|
      @candidate.user.update!(suspended_at: nil, email_verified_at: Time.current, system_role: "member")
      @candidate.user.update!(attributes)
      @event.update!(email_status: "pending", email_attempts: 0)
      assert_no_difference(-> { ActionMailer::Base.deliveries.length }) do
        NotificationEmailDeliveryJob.perform_now(@event.id)
      end
      assert_equal "skipped", @event.reload.email_status
      assert_equal expected_reason, @event.email_status_reason
      assert_nil @event.email_sent_at
    end
  end

  test "a deleted subject cannot send stale assignment content" do
    @event.update!(subject_id: 0)
    assert_no_difference(-> { ActionMailer::Base.deliveries.length }) do
      NotificationEmailDeliveryJob.perform_now(@event.id)
    end
    assert_equal "skipped", @event.reload.email_status
    assert_equal "missing_subject", @event.email_status_reason
  end

  test "an award queued before cancellation is skipped instead of sending an outdated acceptance" do
    @assignment.cancel!(actor: @owner.user)

    assert_no_difference(-> { ActionMailer::Base.deliveries.length }) do
      NotificationEmailDeliveryJob.perform_now(@event.id)
    end
    assert_equal "skipped", @event.reload.email_status
    assert_equal "superseded_event", @event.email_status_reason
    assert_nil @event.email_sent_at
  end

  test "a new proposal withdrawn before email delivery does not send the old arrival message" do
    assignment = create_assignment_for(@owner, title: "Withdrawn before delivery")
    proposal = create_proposal_for(assignment, @candidate)
    event = @owner.user.notifications.find_by!(kind: "new_proposal", subject: proposal)
    proposal.withdraw!(actor: @candidate.user)

    assert_no_difference(-> { ActionMailer::Base.deliveries.length }) do
      NotificationEmailDeliveryJob.perform_now(event.id)
    end
    assert_equal "skipped", event.reload.email_status
    assert_equal "superseded_event", event.email_status_reason
  end

  private

  def with_delivery_failure
    original = MarketplaceMailer.method(:proposal_accepted)
    message = Mail.new(to: @candidate.user.email_address)
    delivery = Object.new
    delivery.define_singleton_method(:message) { message }
    delivery.define_singleton_method(:deliver_now) { raise IOError, "Sensitive synthetic SMTP details" }
    MarketplaceMailer.define_singleton_method(:proposal_accepted) { |*args, **kwargs| delivery }
    yield message
  ensure
    MarketplaceMailer.define_singleton_method(:proposal_accepted, original) if original
  end
end
