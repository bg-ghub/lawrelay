module Admin
  class PrivacyRequestsController < BaseController
    before_action :set_privacy_request, only: :update

    def index
      @privacy_requests = PrivacyRequest.includes(:user, :handled_by_user).order(created_at: :desc)
    end

    def update
      decision = params[:decision].to_s
      note = params.dig(:privacy_request, :resolution_note).to_s.strip
      return invalid_decision unless decision.in?(%w[review complete reject])
      return missing_note if decision.in?(%w[complete reject]) && note.blank?

      if decision == "review"
        @privacy_request.update!(status: "in_review", handled_by_user: current_user)
      else
        status = decision == "complete" ? "completed" : "rejected"
        @privacy_request.close!(status: status, reviewer: current_user, note: note)
      end
      record_audit(decision, note)
      redirect_to admin_privacy_requests_path, notice: t("trust.admin.notices.updated")
    end

    private

    def set_privacy_request
      @privacy_request = PrivacyRequest.find(params[:id])
    end

    def record_audit(decision, note)
      @privacy_request.audit_events.create!(
        actor_user: current_user,
        firm: current_firm,
        action: "privacy_request.#{decision}",
        metadata: { note: note.presence }.compact
      )
    end

    def invalid_decision
      redirect_to admin_privacy_requests_path, alert: t("trust.admin.notices.invalid_decision")
    end

    def missing_note
      redirect_to admin_privacy_requests_path, alert: t("trust.admin.notices.note_required")
    end
  end
end
