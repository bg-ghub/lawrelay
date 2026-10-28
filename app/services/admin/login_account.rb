module Admin
  class LoginAccount
    class << self
      def account
        configured_id = ENV["LAWRELAY_ADMIN_USER_ID"].presence
        return configured_account(configured_id) if configured_id

        sole_system_admin
      end

      def authenticate(password)
        candidate = account
        authenticated_user = candidate&.authenticate(password)
        authenticated_user if authenticated_user && authenticated_user.system_admin? && authenticated_user.active?
      end

      private

      def configured_account(configured_id)
        User.find_by(id: configured_id, system_role: "admin")
      end

      def sole_system_admin
        administrators = User.where(system_role: "admin").limit(2).to_a
        administrators.sole if administrators.one?
      end
    end
  end
end
