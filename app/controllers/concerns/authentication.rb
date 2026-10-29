module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      return request_authentication unless resume_session

      require_two_factor_authentication
    end

    def require_two_factor_authentication
      return if current_user.system_admin? || !current_user.two_factor_enabled? || Current.session.two_factor_verified?
      return if controller_path == "two_factor_authentications" && action_name.in?(%w[challenge verify])
      return if controller_path == "sessions" && action_name == "destroy"

      session[:return_to_after_two_factor] = request.fullpath if request.get? || request.head?
      redirect_to challenge_two_factor_authentication_path, alert: t("two_factor.notices.required")
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      session_id = cookies.signed[:session_id]
      return unless session_id

      resumed_session = Session.includes(:user).find_by(id: session_id)
      return unless resumed_session

      if resumed_session.expired? || !resumed_session.user.active?
        resumed_session.destroy!
        cookies.delete(:session_id)
        return
      end

      resumed_session.record_activity!
      resumed_session
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.fullpath
      destination = admin_host? || controller_path.start_with?("admin/") ? admin_login_path : new_session_path
      redirect_to destination
    end

    def after_authentication_url
      url_from(session.delete(:return_to_after_authenticating)) || (current_user.system_admin? ? admin_users_path : dashboard_path)
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed[:session_id] = {
          value: session.id,
          expires: session.expires_at,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?
        }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
