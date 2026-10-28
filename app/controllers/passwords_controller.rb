class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: t("auth.passwords.rate_limited") }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      PasswordsMailer.reset(user).deliver_later
    end

    redirect_to new_session_path, notice: t("auth.passwords.sent")
  end

  def edit
  end

  def update
    updated = @user.with_lock do
      User.find_by_password_reset_token!(params[:token])
      if params[:password].present? && @user.update(params.permit(:password, :password_confirmation))
        @user.sessions.destroy_all
        true
      else
        false
      end
    end

    if updated
      destination = @user.system_admin? ? admin_login_path : new_session_path
      redirect_to destination, notice: t("auth.passwords.reset")
    else
      redirect_to edit_password_path(token: params[:token]), alert: t("auth.passwords.invalid_password")
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_password_path, alert: t("auth.passwords.invalid")
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: t("auth.passwords.invalid")
    end
end
