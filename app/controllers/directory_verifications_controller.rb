class DirectoryVerificationsController < ApplicationController
  allow_unauthenticated_access

  def show
    @profile = Directory::ConfirmationToken.find_profile!(params[:token])
    @user = @profile.user
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("directory_mail.notices.invalid")
  end

  def confirm
    profile = Directory::ConfirmationToken.find_profile!(params[:token])
    result = Directory::Verification.confirm!(profile)
    if result.status == :already_claimed
      redirect_to new_session_path(locale: profile.user.locale), alert: t("directory_mail.notices.already_claimed")
      return
    end

    redirect_to new_session_path(locale: profile.user.locale), notice: t("directory_mail.notices.confirmed")
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_session_path, alert: t("directory_mail.notices.invalid")
  end
end
