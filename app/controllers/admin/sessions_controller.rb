module Admin
  class SessionsController < ApplicationController
    allow_unauthenticated_access only: %i[new create]
    rate_limit to: 10, within: 3.minutes, only: :create,
      with: -> { redirect_to admin_login_path, alert: t("admin.login.rate_limited") }

    def new
      set_password_reset_email
    end

    def create
      user = LoginAccount.authenticate(params[:password])
      if user&.active?
        start_new_session_for(user)
        redirect_to after_authentication_url
      else
        set_password_reset_email
        flash.now[:alert] = t("admin.login.invalid")
        render :new, status: :unprocessable_content
      end
    end

    private

    def set_password_reset_email
      @password_reset_email = LoginAccount.account&.email_address || "admin@lawrelay.be"
    end
  end
end
