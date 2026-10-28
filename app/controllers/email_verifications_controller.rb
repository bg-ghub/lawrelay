class EmailVerificationsController < ApplicationController
  allow_unauthenticated_access

  def show
    @user = User.find_by_email_verification_token!(params[:token])
    raise ActiveSupport::MessageVerifier::InvalidSignature unless @user.active?
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("auth.email_verification.invalid")
  end

  def confirm
    user = User.find_by_email_verification_token!(params[:token])
    user.with_lock do
      # A settings request may change the address after the first lookup.
      User.find_by_email_verification_token!(params[:token])
      raise ActiveSupport::MessageVerifier::InvalidSignature unless user.active?
      user.update!(email_verified_at: Time.current) unless user.email_verified?
    end
    Directory::Verification.activate_if_ready!(user: user)

    if authenticated? && Current.user == user
      destination = if user.system_admin?
        admin_users_path
      else
        user.reload.marketplace_verified? ? dashboard_path : verification_status_path
      end
      redirect_to destination, notice: t("auth.email_verification.verified")
    else
      redirect_to new_session_path, notice: t("auth.email_verification.verified_sign_in")
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("auth.email_verification.invalid")
  end
end
