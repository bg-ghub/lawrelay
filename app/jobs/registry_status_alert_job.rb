class RegistryStatusAlertJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: ->(executions) { RegistryStatusRun::ALERT_RETRY_DELAYS.fetch(executions - 1, 1.hour) }, attempts: 5

  def perform(run_id)
    run = RegistryStatusRun.find_by(id: run_id)
    RegistryStatus::Cleanup.new.call if run
    run&.discard_irrelevant_findings!
    return unless run&.claim_alert_delivery!

    delivery = RegistryStatusMailer.daily_alert(run)
    email = delivery.message
    raise "Registry status alert recipient unavailable" if email.to.blank?

    email.message_id = "registry-status-#{run.id}@#{ENV.fetch('APP_HOST', 'lawrelay.be').split(':').first}"
    return unless run.current_alert_claim?

    delivery.deliver_now
    run.finish_alert_delivery!
  rescue StandardError => error
    run&.fail_alert_delivery!(error:) if run&.alert_status == "sending"
    raise
  end
end
