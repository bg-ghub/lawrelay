class VerificationStatusController < ApplicationController
  rate_limit to: 3, within: 1.hour, by: -> { current_user.id }, name: "confirmation-account", only: :create,
    with: -> { redirect_to verification_status_path, alert: t("auth.verification_status.rate_limited") }
  rate_limit to: 10, within: 1.hour, name: "confirmation-ip", only: :create,
    with: -> { redirect_to verification_status_path, alert: t("auth.verification_status.rate_limited") }
  rate_limit to: 3, within: 15.minutes, name: "directory-retry", only: :retry_directory,
    with: -> { redirect_to verification_status_path, alert: t("directory_onboarding.status.retry_rate_limited") }

  def show
    load_status
    redirect_to dashboard_path if @user.marketplace_verified?
  end

  def create
    confirmation_required = Current.user.email_verification_required?
    queued = !confirmation_required || Onboarding::Delivery.enqueue { EmailVerificationMailer.verify(Current.user).deliver_later }
    record_confirmation_resend(queued:) if confirmation_required
    if queued
      redirect_to verification_status_path, notice: t("auth.verification_status.resent")
    else
      redirect_to verification_status_path, alert: t("auth.verification_status.queue_unavailable")
    end
  end

  def retry_directory
    if Onboarding::Delivery.enqueue { Directory::VerificationJob.perform_later(Current.user.id) }
      redirect_to verification_status_path, notice: t("directory_onboarding.status.retry_queued")
    else
      redirect_to verification_status_path, alert: t("auth.verification_status.queue_unavailable")
    end
  end

  private

  def record_confirmation_resend(queued:)
    user = Current.user
    event = AuditEvent.create!(auditable: user, actor_user: user, action: "account.confirmation_resend_requested",
      metadata: { recipient_domain: user.email_address.to_s.rpartition("@").last, delivery_queued: queued })
    Onboarding::Delivery.enqueue { ConfirmationResendAlertJob.perform_later(event.id) }
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.warn("Confirmation resend audit unavailable: #{error.class}")
  end

  def load_status
    @user = Current.user
    @firm = @user.primary_firm
    @lawyer_profile = @user.lawyer_profile
  end
end
