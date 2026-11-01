class ConfirmationResendAlertJob < ApplicationJob
  class DeliveryFailure < StandardError; end

  queue_as :default
  retry_on DeliveryFailure, wait: 1.minute, attempts: 3

  CLAIM_LEASE = 2.minutes

  def perform(event_id)
    event = AuditEvent.find_by(id: event_id)
    return unless ConfirmationResendMailer.alertable_event?(event)

    claim = claim_delivery(event)
    raise DeliveryFailure, "Confirmation resend alert delivery in progress" if claim == :busy
    return unless claim

    delivery = ConfirmationResendMailer.requested(event)
    email = delivery.message
    raise DeliveryFailure, "Confirmation resend alert recipient unavailable" if email.to.blank?

    email.message_id = "confirmation-resend-#{event.id}@lawrelay.be"
    delivery.deliver_now
    event.with_lock do
      next unless event.metadata["resend_alert_claimed_at"] == claim

      event.update!(metadata: event.metadata.except("resend_alert_claimed_at").merge("resend_alert_sent_at" => Time.current.utc.iso8601(6)))
    end
  rescue StandardError => error
    release_claim(event, claim) if event && claim
    Rails.logger.warn("Confirmation resend alert unavailable: #{error.class}")
    raise DeliveryFailure, "Confirmation resend alert unavailable", cause: nil
  end

  private

  def claim_delivery(event)
    event.with_lock do
      return unless ConfirmationResendMailer.alertable_event?(event)
      return if event.metadata["resend_alert_sent_at"].present?

      previous_claim = Time.iso8601(event.metadata["resend_alert_claimed_at"].to_s) rescue nil
      return :busy if previous_claim && previous_claim > CLAIM_LEASE.ago

      claim = Time.current.utc.iso8601(6)
      event.update!(metadata: event.metadata.merge("resend_alert_claimed_at" => claim))
      claim
    end
  end

  def release_claim(event, claim)
    event.with_lock do
      next unless event.metadata["resend_alert_claimed_at"] == claim

      event.update!(metadata: event.metadata.except("resend_alert_claimed_at"))
    end
  rescue StandardError => error
    Rails.logger.warn("Confirmation resend alert claim unavailable: #{error.class}")
  end
end
