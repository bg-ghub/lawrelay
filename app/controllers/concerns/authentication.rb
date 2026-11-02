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
      return if performed?

      require_deletion_recovery_scope
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
      unless resumed_session
        cookies.delete(:session_id)
        return
      end

      if resumed_session.expired? || !session_user_available?(resumed_session.user)
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
      if current_user.deletion_pending?
        session.delete(:return_to_after_authenticating)
        return account_deletion_path
      end

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

    def start_password_session_for(user, password:, admin: false)
      return unless user

      authenticated_email = user.email_address
      user.with_lock do
        # Credential changes and session revocation take this same user lock.
        # Recheck the password after reloading, before issuing any new session.
        next unless session_user_available?(user) && user.email_address == authenticated_email
        next if admin && !user.system_admin?
        next unless user.authenticate(password.to_s)

        start_new_session_for(user)
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end

    def session_user_available?(user)
      user && (user.active? || user.deletion_recoverable?)
    end

    def require_deletion_recovery_scope
      return unless current_user.deletion_pending?
      return if controller_path == "account_deletions" && action_name.in?(%w[show cancel])
      return if controller_path == "privacy_requests" && action_name.in?(%w[index new create])
      return if controller_path == "two_factor_authentications" && action_name.in?(%w[challenge verify])
      return if controller_path == "sessions" && action_name == "destroy"

      redirect_to account_deletion_path, status: :see_other
    end
end
