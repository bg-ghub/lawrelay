module Admin
  class BaseController < ApplicationController
    before_action :require_system_admin
    before_action :require_admin_mfa

    private

    def find_user_resource!(scope)
      identifier = params[:id].to_s
      if User::PUBLIC_ID_FORMAT.match?(identifier)
        scope.find_by!(public_id: identifier)
      elsif /\A[1-9]\d{0,18}\z/.match?(identifier)
        # Keep existing bookmarks and forms bound to the same internal record.
        scope.find(identifier.to_i)
      else
        raise ActiveRecord::RecordNotFound
      end
    end

    def redirect_legacy_user_resource(user, canonical_path)
      return unless request.get? || request.head?
      return if params[:id] == user.public_id

      response.headers["Cache-Control"] = "no-store"
      redirect_to canonical_path, status: :moved_permanently
    end

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
