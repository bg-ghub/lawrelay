class EmailVerificationsController < ApplicationController
  allow_unauthenticated_access

  def show
    user = User.find_by_email_verification_token!(params[:token])
    user.update!(email_verified_at: Time.current) unless user.email_verified?

    if authenticated? && Current.user == user
      redirect_to verification_status_path, notice: t("auth.email_verification.verified")
    else
      redirect_to new_session_path, notice: t("auth.email_verification.verified_sign_in")
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("auth.email_verification.invalid")
  end
end
