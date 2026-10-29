class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: t("auth.sessions.rate_limited") }

  def new
  end

  def create
    user = User.authenticate_by(params.permit(:email_address, :password))
    if user&.active?
      start_new_session_for user
      if !user.system_admin? && user.two_factor_enabled?
        session[:return_to_after_two_factor] = after_authentication_url
        redirect_to challenge_two_factor_authentication_path
      else
        redirect_to after_authentication_url
      end
    else
      redirect_to new_session_path, alert: t("auth.sessions.invalid")
    end
  end

  def destroy
    terminate_session
    redirect_to authentication_login_path, status: :see_other
  end
end
