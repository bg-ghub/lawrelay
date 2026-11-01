require "test_helper"

class ConfirmationResendAlertJobTest < ActiveJob::TestCase
  setup do
    @member = users(:one)
    @event = AuditEvent.create!(auditable: @member, actor_user: @member,
      action: "account.confirmation_resend_requested", metadata: { recipient_domain: "advocaat.be", delivery_queued: true })
    clear_enqueued_jobs
  end

  test "one alert is delivered per request and replay uses the recorded sent marker" do
    with_delivery do |messages, requests|
      ConfirmationResendAlertJob.perform_now(@event.id)
      ConfirmationResendAlertJob.perform_now(@event.id)

      assert_equal [ @event.id ], requests
      assert_equal 1, messages.length
      assert_equal "confirmation-resend-#{@event.id}@lawrelay.be", messages.first.message_id
    end
    assert @event.reload.metadata["resend_alert_sent_at"].present?
    assert_nil @event.metadata["resend_alert_claimed_at"]
    assert_equal "advocaat.be", @event.metadata["recipient_domain"]
  end

  test "a separate eligible request generates a separate alert" do
    second = AuditEvent.create!(auditable: @member, actor_user: @member,
      action: @event.action, metadata: @event.metadata)

    with_delivery do |messages, requests|
      ConfirmationResendAlertJob.perform_now(@event.id)
      ConfirmationResendAlertJob.perform_now(second.id)

      assert_equal [ @event.id, second.id ], requests
      assert_equal 2, messages.length
      assert_not_equal messages.first.message_id, messages.last.message_id
    end
  end

  test "missing, unrelated and erased-member events do not deliver" do
    @event.update!(action: "account.updated")
    with_delivery do |messages, requests|
      ConfirmationResendAlertJob.perform_now(@event.id)
      ConfirmationResendAlertJob.perform_now(-1)
      @event.update!(action: "account.confirmation_resend_requested")
      @member.update!(erased_at: Time.current)
      ConfirmationResendAlertJob.perform_now(@event.id)

      assert_empty messages
      assert_empty requests
    end
  end

  test "provider failures are sanitized and a retry keeps the same message id" do
    failed_id = nil
    with_delivery(error: IOError.new("Sensitive synthetic SMTP response")) do |messages|
      error = assert_raises(ConfirmationResendAlertJob::DeliveryFailure) { ConfirmationResendAlertJob.new.perform(@event.id) }
      assert_equal "Confirmation resend alert unavailable", error.message
      assert_nil error.cause
      failed_id = messages.first.message_id
    end
    assert_nil @event.reload.metadata["resend_alert_sent_at"]
    assert_nil @event.metadata["resend_alert_claimed_at"]
    assert_not_includes @event.attributes.to_json, "Sensitive synthetic SMTP response"

    with_delivery do |messages|
      ConfirmationResendAlertJob.perform_now(@event.id)
      assert_equal failed_id, messages.first.message_id
    end
  end

  test "an active delivery claim avoids duplicates and an abandoned claim can recover" do
    @event.update!(metadata: @event.metadata.merge("resend_alert_claimed_at" => Time.current.utc.iso8601(6)))
    with_delivery do |messages, requests|
      assert_enqueued_with(job: ConfirmationResendAlertJob, args: [ @event.id ]) do
        ConfirmationResendAlertJob.perform_now(@event.id)
      end
      assert_empty messages
      assert_empty requests

      travel ConfirmationResendAlertJob::CLAIM_LEASE + 1.second do
        ConfirmationResendAlertJob.perform_now(@event.id)
        assert_equal 1, messages.length
      end
    end
  end

  test "temporary failures schedule a retry without raw provider details" do
    with_delivery(error: IOError.new("Sensitive synthetic SMTP response")) do
      assert_enqueued_with(job: ConfirmationResendAlertJob, args: [ @event.id ]) do
        ConfirmationResendAlertJob.perform_now(@event.id)
      end
    end
    assert_not_includes enqueued_jobs.inspect, "Sensitive synthetic SMTP response"
  end

  private

  def with_delivery(error: nil)
    original = ConfirmationResendMailer.method(:requested)
    messages = []
    requests = []
    ConfirmationResendMailer.define_singleton_method(:requested) do |event|
      requests << event.id
      message = Mail.new(to: "support@example.test")
      delivery = Object.new
      delivery.define_singleton_method(:message) { message }
      delivery.define_singleton_method(:deliver_now) do
        messages << message
        raise error if error
        message
      end
      delivery
    end
    yield messages, requests
  ensure
    ConfirmationResendMailer.define_singleton_method(:requested, original) if original
  end
end
