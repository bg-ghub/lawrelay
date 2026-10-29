module Admin
  class BaseController < ApplicationController
    before_action :require_system_admin
    before_action :require_admin_mfa

    private

    def request_authentication
      session[:return_to_after_authenticating] = request.fullpath
      redirect_to admin_login_path
    end

    def require_admin_mfa
      return if Current.session&.admin_mfa_verified?

      session[:return_to_after_admin_mfa] = request.fullpath
      destination = current_user.admin_mfa_configured? ? admin_mfa_challenge_path : admin_mfa_setup_path
      redirect_to destination, alert: t("mfa.notices.required")
    end
  end
end
