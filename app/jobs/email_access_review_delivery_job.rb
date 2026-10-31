class EmailAccessReviewDeliveryJob < ApplicationJob
  retry_on Onboarding::MailTransport::TemporaryFailure, wait: 1.minute, attempts: 3

  def perform(profile_id, reviewed_at)
    profile = LawyerProfile.find_by(id: profile_id)
    return unless profile && profile.email_review_status.in?(%w[approved rejected]) &&
      profile.email_reviewed_at&.utc&.iso8601(6) == reviewed_at
    user = profile.user
    return unless user.active? && user.email_verified? && profile.email_review_email_address == user.email_address
    return unless profile.email_review_identity_digest.present? &&
      profile.email_review_identity_digest == profile.email_review_current_identity_digest
    return if profile.email_review_status == "approved" && (!profile.email_review_approved? || !user.marketplace_verified?)

    delivery = EmailAccessReviewMailer.decision(profile)
    Onboarding::MailTransport.protect(delivery.message)
    delivery.deliver_now
  end
end
