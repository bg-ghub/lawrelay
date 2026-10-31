require "test_helper"

class RegistryStatusAlertJobTest < ActiveJob::TestCase
  setup do
    firm = Firm.create!(name: "Registry alert example", enterprise_number: "0123456749")
    users(:one).memberships.create!(firm:, role: "member")
    target = RegistryStatus::Targets.all.find { |candidate| candidate.firm_id == firm.id }
    @check = RegistryStatusCheck.create!(source: target.source, target_digest: target.digest,
      identity_digest: target.identity_digest, firm_id: firm.id)
    @check.record_result!(outcome: "inactive", checked_at: Time.current,
      run_on: Date.current, identity_digest: target.identity_digest)
    @run = RegistryStatusRun.create!(run_on: Date.current, status: "completed", completed_at: Time.current,
      findings: [ @check.finding_snapshot ], alert_status: "pending")
    clear_enqueued_jobs
  end

  test "one consolidated alert is sent once with a deterministic message id" do
    with_delivery do |messages, requests|
      RegistryStatusAlertJob.perform_now(@run.id)
      RegistryStatusAlertJob.perform_now(@run.id)

      assert_equal [ @run.id ], requests
      assert_equal 1, messages.length
      assert_equal "registry-status-#{@run.id}@#{ENV.fetch('APP_HOST', 'lawrelay.be').split(':').first}", messages.first.message_id
    end
    assert_equal "sent", @run.reload.alert_status
    assert_equal 1, @run.alert_attempts
    assert @run.alert_sent_at
    assert_nil @run.alert_claimed_at
    assert_equal @run.alert_sent_at, @check.reload.last_alerted_at
  end

  test "a member erased before delivery removes the finding and cancels an empty alert" do
    users(:one).update!(erased_at: Time.current)

    with_delivery do |messages, requests|
      RegistryStatusAlertJob.perform_now(@run.id)
      assert_empty messages
      assert_empty requests
    end

    assert_empty @run.reload.findings
    assert_nil @run.alert_status
    assert_equal 0, @run.alert_attempts
    assert_not RegistryStatusCheck.exists?(@check.id)
  end

  test "missing and incomplete runs cannot deliver an alert" do
    @run.update!(status: "running", completed_at: nil)

    with_delivery do |messages, requests|
      RegistryStatusAlertJob.perform_now(@run.id)
      RegistryStatusAlertJob.perform_now(-1)

      assert_empty messages
      assert_empty requests
    end
    assert_equal 0, @run.reload.alert_attempts
  end

  test "a delivery failure persists a retry without storing SMTP details and retry uses the same id" do
    failed_message_id = nil
    with_delivery(error: IOError.new("Sensitive synthetic SMTP details")) do |messages|
      error = assert_raises(IOError) { RegistryStatusAlertJob.new.perform(@run.id) }
      assert_equal "Sensitive synthetic SMTP details", error.message
      failed_message_id = messages.first.message_id
    end

    assert_equal "pending", @run.reload.alert_status
    assert_equal "IOError", @run.alert_status_reason
    assert_equal 1, @run.alert_attempts
    assert @run.alert_retry_at > Time.current
    assert_not_includes @run.attributes.to_json, "Sensitive synthetic SMTP details"
    assert_nil @check.reload.last_alerted_at

    travel_to @run.alert_retry_at + 1.second do
      with_delivery do |messages|
        RegistryStatusAlertJob.perform_now(@run.id)
        assert_equal failed_message_id, messages.first.message_id
      end
    end
    assert_equal "sent", @run.reload.alert_status
    assert_equal 2, @run.alert_attempts
    assert_equal @run.alert_sent_at, @check.reload.last_alerted_at
  end

  test "an active alert lease prevents duplicates and an abandoned lease can recover" do
    assert @run.claim_alert_delivery!

    with_delivery do |messages, requests|
      RegistryStatusAlertJob.perform_now(@run.id)
      assert_empty messages
      assert_empty requests
    end

    travel_to @run.alert_claimed_at + RegistryStatusRun::ALERT_LEASE + 1.second do
      with_delivery do |messages|
        RegistryStatusAlertJob.perform_now(@run.id)
        assert_equal 1, messages.length
      end
    end
    assert_equal "sent", @run.reload.alert_status
    assert_equal 2, @run.alert_attempts
  end

  test "exhausted delivery attempts persist failure and further jobs do not send" do
    @run.update!(alert_attempts: RegistryStatusRun::MAX_ALERT_ATTEMPTS - 1)

    with_delivery(error: IOError.new("Sensitive synthetic SMTP details")) do
      assert_raises(IOError) { RegistryStatusAlertJob.new.perform(@run.id) }
    end
    assert_equal "failed", @run.reload.alert_status
    assert_equal RegistryStatusRun::MAX_ALERT_ATTEMPTS, @run.alert_attempts
    assert_nil @run.alert_retry_at
    assert RegistryStatusRun.alert_delivery_unhealthy?

    with_delivery do |messages, requests|
      RegistryStatusAlertJob.perform_now(@run.id)
      assert_empty messages
      assert_empty requests
    end
  end

  test "operational health exposes stale pending and sending alerts without showing findings" do
    now = Time.current.change(usec: 0)
    @run.update!(created_at: now - 16.minutes)
    assert RegistryStatusRun.alert_delivery_unhealthy?(now:)

    @run.update!(created_at: now, alert_retry_at: now + 1.minute)
    assert_not RegistryStatusRun.alert_delivery_unhealthy?(now:)

    @run.update!(alert_status: "sending", alert_claimed_at: now - RegistryStatusRun::ALERT_LEASE - 1.second)
    assert RegistryStatusRun.alert_delivery_unhealthy?(now:)

    @run.update!(alert_status: "sent", alert_claimed_at: nil, alert_sent_at: now)
    assert_not RegistryStatusRun.alert_delivery_unhealthy?(now:)
  end

  private

  def with_delivery(error: nil)
    original = RegistryStatusMailer.method(:daily_alert)
    messages = []
    requests = []
    RegistryStatusMailer.define_singleton_method(:daily_alert) do |run|
      requests << run.id
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
    RegistryStatusMailer.define_singleton_method(:daily_alert, original) if original
  end
end
