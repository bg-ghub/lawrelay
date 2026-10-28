module Admin
  class UsersController < BaseController
    before_action :set_user, except: :index

    def index
      @query = params[:q].to_s.strip.first(100)
      @status_filter = params[:status].presence_in(%w[active suspended]).to_s
      @verification_filter = params[:verification].presence_in(LawyerProfile::VERIFICATION_STATUSES).to_s
      @role_filter = params[:role].presence_in(User::SYSTEM_ROLES).to_s
      @per_page = params[:per_page].to_i == 50 ? 50 : 25

      scope = User.left_joins(:lawyer_profile, memberships: :firm)
      scope = apply_search(scope)
      scope = scope.where(suspended_at: nil) if @status_filter == "active"
      scope = scope.where.not(suspended_at: nil) if @status_filter == "suspended"
      scope = scope.where(system_role: @role_filter) if @role_filter.present?
      scope = apply_verification_filter(scope)
      @total_count = scope.distinct.count
      @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
      @page = params[:page].to_i.clamp(1, @total_pages)
      @users = scope.distinct.includes(:lawyer_profile, memberships: :firm)
        .order(created_at: :desc, id: :desc).offset((@page - 1) * @per_page).limit(@per_page)
    end

    def show
      load_details
    end

    def update
      result = manager.update!(account_params)
      if @user.active?
        EmailVerificationMailer.verify(@user).deliver_later if result.email_changed
        profile = @user.lawyer_profile
        if result.identity_changed && profile&.directory_profile_url.present? && !profile.verification_status.in?(%w[rejected suspended])
          Directory::VerificationJob.perform_later(@user.id)
        end
      end
      redirect_to admin_user_path(@user), notice: t("admin.users.notices.updated")
    rescue UserManagement::InvalidAction => error
      management_error(error.translation_key)
    rescue ActiveRecord::RecordInvalid
      management_error("admin.users.errors.invalid_details")
    end

    def suspend
      manager.suspend!(reason: action_reason)
      redirect_to admin_user_path(@user), notice: t("admin.users.notices.suspended")
    rescue UserManagement::InvalidAction => error
      management_error(error.translation_key)
    end

    def restore
      manager.restore!(reason: action_reason)
      redirect_to admin_user_path(@user), notice: t("admin.users.notices.restored")
    rescue UserManagement::InvalidAction => error
      management_error(error.translation_key)
    end

    def revoke_sessions
      manager.revoke_sessions!(reason: action_reason)
      redirect_to admin_user_path(@user), notice: t("admin.users.notices.sessions_revoked")
    rescue UserManagement::InvalidAction => error
      management_error(error.translation_key)
    end

    private

    def set_user
      @user = User.includes(:lawyer_profile, memberships: :firm).find(params[:id])
    end

    def manager
      UserManagement.new(actor: current_user, user: @user)
    end

    def account_params
      params.fetch(:user, {}).permit(:first_name, :last_name, :email_address, :locale).to_h
    end

    def action_reason
      params.dig(:user_management, :reason)
    end

    def load_details
      @profile = @user.lawyer_profile
      @firm = @user.primary_firm
      @sessions = @user.sessions.where("expires_at > ?", Time.current).order(last_seen_at: :desc).limit(20)
      events = AuditEvent.where(auditable: @user)
      events = events.or(AuditEvent.where(auditable: @profile)) if @profile
      @audit_events = events.includes(:actor_user).order(created_at: :desc, id: :desc).limit(30)
    end

    def management_error(key)
      @management_error = t(key)
      load_details
      render :show, status: :unprocessable_content
    end

    def apply_search(scope)
      return scope if @query.blank?

      term = "%#{User.sanitize_sql_like(@query.downcase)}%"
      scope.where(
        "LOWER(users.first_name || ' ' || users.last_name) LIKE :term OR " \
        "LOWER(users.email_address) LIKE :term OR LOWER(firms.name) LIKE :term",
        term:
      )
    end

    def apply_verification_filter(scope)
      return scope if @verification_filter.blank?

      if @verification_filter == "pending"
        scope.where("lawyer_profiles.id IS NULL OR lawyer_profiles.verification_status = ?", "pending")
      elsif @verification_filter == "verified"
        scope.where(lawyer_profiles: { verification_status: "verified" }).where.not(lawyer_profiles: { verified_at: nil })
      else
        scope.where(lawyer_profiles: { verification_status: @verification_filter })
      end
    end
  end
end
