class NotificationEmailDeliveryJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: ->(executions) { Notification::EMAIL_RETRY_DELAYS.fetch(executions - 1, 1.hour) }, attempts: 5

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification&.claim_email_delivery!

    recipient = notification.user.reload
    reason = skip_reason(notification, recipient)
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

  private

  def skip_reason(notification, recipient)
    return "inactive_recipient" unless recipient.active?
    return "administrator_recipient" if recipient.system_admin?
    return "unverified_recipient" unless recipient.email_verified?
    return "unverified_marketplace_recipient" unless recipient.marketplace_verified?
    return "unsupported_event" unless notification.kind.in?(Notification::EMAIL_KINDS)

    subject = notification.subject
    return "missing_subject" unless subject

    assignment = subject.is_a?(Proposal) ? subject.assignment : subject
    return "missing_assignment" unless assignment.is_a?(Assignment)
    return "assignment_unavailable" unless assignment.visible_to?(recipient)

    "superseded_event" unless current_event?(notification.kind, subject, assignment)
  end

  def current_event?(kind, subject, assignment, now: Time.current)
    case kind
    when "new_proposal"
      subject.is_a?(Proposal) && subject.status == "pending" && assignment.status == "open"
    when "proposal_accepted"
      subject.is_a?(Proposal) && subject.status == "accepted" && assignment.status == "matched"
    when "proposal_declined"
      subject.is_a?(Proposal) && subject.status == "declined"
    when "proposal_withdrawn"
      subject.is_a?(Proposal) && subject.status == "withdrawn" && assignment.status == "open"
    when "assignment_matched", "assignment_completed", "assignment_cancelled", "assignment_expired"
      assignment.status == kind.delete_prefix("assignment_")
    when "response_deadline_closed"
      assignment.status == "open" && assignment.response_deadline_at.present? &&
        assignment.response_deadline_at <= now && assignment.starts_at > now
    else
      false
    end
  end
end
