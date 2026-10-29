module Admin
  class VerificationsController < BaseController
    before_action :set_user, only: :update

    def index
      @users = User.left_joins(:lawyer_profile, memberships: :firm)
        .includes(:lawyer_profile, memberships: :firm)
        .where.not(system_role: "admin")
        .where(
          "lawyer_profiles.id IS NULL OR firms.id IS NULL OR " \
          "lawyer_profiles.verification_status = :pending OR firms.verification_status = :pending",
          pending: "pending"
        )
        .distinct
        .order(created_at: :asc)
    end

    def update
      decision = params[:decision].to_s
      return redirect_invalid_decision unless decision.in?(%w[approve reject])

      firm = @user.primary_firm
      profile = @user.lawyer_profile
      unless firm && profile
        return redirect_to admin_verifications_path,
          alert: t("admin.verifications.notices.incomplete_account")
      end

      status = decision == "approve" ? "verified" : "rejected"
      outcome = decision == "approve" ? "approved" : "rejected"
      verified_at = status == "verified" ? Time.current : nil
      note = verification_params[:note].to_s.strip.presence

      ApplicationRecord.transaction do
        firm.update!(verification_status: status, verified_at: verified_at)
        profile.update!(
          verification_status: status,
          verified_at: verified_at,
          verification_note: note
        )
        record_audit_event(firm, outcome, note)
        record_audit_event(profile, outcome, note)
      end

      redirect_to admin_verifications_path,
        notice: t("admin.verifications.notices.#{outcome}", name: @user.full_name)
    end

    private

    def set_user
      @user = User.where(system_role: "member").includes(:lawyer_profile, memberships: :firm).find(params[:id])
    end

    def verification_params
      params.fetch(:verification, {}).permit(:note)
    end

    def record_audit_event(subject, outcome, note)
      AuditEvent.create!(
        auditable: subject,
        actor_user: current_user,
        firm: subject.is_a?(Firm) ? subject : subject.user.primary_firm,
        action: "verification.#{outcome}",
        metadata: {
          reviewed_user_id: @user.id,
          note: note
        }.compact
      )
    end

    def redirect_invalid_decision
      redirect_to admin_verifications_path,
        alert: t("admin.verifications.notices.invalid_decision")
    end
  end
end
