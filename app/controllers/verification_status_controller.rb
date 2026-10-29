class VerificationStatusController < ApplicationController
  rate_limit to: 3, within: 15.minutes, only: :create,
    with: -> { redirect_to verification_status_path, alert: t("auth.verification_status.rate_limited") }
  rate_limit to: 3, within: 15.minutes, only: :retry_directory,
    with: -> { redirect_to verification_status_path, alert: t("directory_onboarding.status.retry_rate_limited") }

  def show
    load_status
    redirect_to dashboard_path if @user.marketplace_verified?
  end

  def create
    queued = Current.user.email_verified? || Onboarding::Delivery.enqueue { EmailVerificationMailer.verify(Current.user).deliver_later }
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

  def load_status
    @user = Current.user
    @firm = @user.primary_firm
    @lawyer_profile = @user.lawyer_profile
  end
end
