class VerificationStatusController < ApplicationController
  rate_limit to: 3, within: 15.minutes, only: :create,
    with: -> { redirect_to verification_status_path, alert: t("auth.verification_status.rate_limited") }

  def show
    load_status
  end

  def create
    EmailVerificationMailer.verify(Current.user).deliver_later unless Current.user.email_verified?
    redirect_to verification_status_path, notice: t("auth.verification_status.resent")
  end

  private

  def load_status
    @user = Current.user
    @firm = @user.primary_firm
    @lawyer_profile = @user.lawyer_profile
  end
end
