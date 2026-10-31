class DailyRegistryStatusJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "registry-status-provider-checks", duration: 30.minutes
  retry_on StandardError, wait: 5.minutes, attempts: 3

  def perform(run_on = Time.current.utc.to_date.iso8601)
    date = Date.iso8601(run_on.to_s)
    return if date > Time.current.utc.to_date

    run = RegistryStatusRun.find_or_create_by!(run_on: date)
    if date < Time.current.utc.to_date
      run.complete_stale!
      enqueue_alert(run) if run.reload.alert_status == "pending"
      return
    end
    token = run.claim!
    return unless token

    RegistryStatus::Cleanup.new.call
    outcome = RegistryStatus::Checker.new(run:, token:).call
    if outcome == :continue
      self.class.set(wait: 1.second).perform_later(run.run_on.iso8601)
    elsif outcome == :completed && run.reload.alert_status == "pending"
      enqueue_alert(run)
    end
  rescue StandardError
    run&.release!(token) if token
    raise
  end

  private

  def enqueue_alert(run)
    RegistryStatusAlertJob.perform_later(run.id)
  rescue StandardError => error
    Rails.logger.error("Registry status alert enqueue failed: #{error.class} (run #{run.id})")
  end
end
