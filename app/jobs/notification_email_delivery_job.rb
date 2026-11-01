class NotificationEmailDeliveryJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: ->(executions) { Notification::EMAIL_RETRY_DELAYS.fetch(executions - 1, 1.hour) }, attempts: 5

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification&.claim_email_delivery!

    recipient = notification.user.reload
    reason = Notifications::EmailEligibility.new(notification, recipient:).skip_reason
    if reason
      notification.finish_email_delivery!(status: "skipped", reason:)
      return
    end

    delivery = MarketplaceMailer.public_send(notification.kind, notification.subject, recipient:)
    email = delivery.message
    if email.to.blank?
      notification.finish_email_delivery!(status: "skipped", reason: "recipient_unavailable")
      return
    end
    email.message_id = "notification-#{notification.id}@#{ENV.fetch('APP_HOST', 'lawrelay.be').split(':').first}"
    return unless notification.current_email_delivery_claim?

    delivery.deliver_now
    notification.finish_email_delivery!(status: "sent")
  rescue StandardError => error
    notification&.fail_email_delivery!(error:) if notification&.email_status == "sending"
    raise
  end
end
