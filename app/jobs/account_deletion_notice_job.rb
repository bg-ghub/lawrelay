class AccountDeletionNoticeJob < ApplicationJob
  queue_as :default

  def perform(request_id, kind)
    return unless kind.in?(%w[requested cancelled])

    request = AccountDeletionRequest.find_by(id: request_id)
    return unless request&.claim_notice!(kind)

    recipient = request.user.reload
    unless request.notice_eligible?(kind, user: recipient)
      request.finish_notice!(kind, status: "skipped", reason: "recipient_unavailable")
      return
    end

    delivery = AccountDeletionMailer.public_send(kind, request)
    email = delivery.message
    if email.to.blank?
      request.finish_notice!(kind, status: "skipped", reason: "recipient_unavailable")
      return
    end
    email.message_id = "account-deletion-#{request.id}-#{kind}@#{SiteHosts.app_host.split(':').first}"
    return unless request.notice_claim_current?(kind)
    unless request.notice_eligible?(kind, user: recipient.reload)
      request.finish_notice!(kind, status: "skipped", reason: "recipient_unavailable")
      return
    end

    delivery.deliver_now
    request.finish_notice!(kind, status: "sent")
  rescue StandardError => error
    request&.fail_notice!(kind, error:)
    Rails.logger.error("Account deletion notice failed: #{error.class} (request #{request_id})")
  end
end
