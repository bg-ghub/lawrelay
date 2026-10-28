module Admin
  class ReportsController < BaseController
    before_action :set_report, only: :update

    def index
      @reports = Report.includes(:reporter_user, :reportable).order(created_at: :desc)
    end

    def update
      decision = params[:decision].to_s
      note = params.dig(:report, :resolution_note).to_s.strip
      return invalid_decision unless decision.in?(%w[review resolve dismiss])
      return missing_note if decision.in?(%w[resolve dismiss]) && note.blank?

      if decision == "review"
        @report.update!(status: "in_review", reviewed_by_user: current_user)
      else
        status = decision == "resolve" ? "resolved" : "dismissed"
        @report.close!(status: status, reviewer: current_user, note: note)
      end
      record_audit(decision, note)
      redirect_to admin_reports_path, notice: t("trust.admin.notices.updated")
    end

    private

    def set_report
      @report = Report.find(params[:id])
    end

    def record_audit(decision, note)
      @report.audit_events.create!(
        actor_user: current_user,
        firm: current_firm,
        action: "report.#{decision}",
        metadata: { note: note.presence }.compact
      )
    end

    def invalid_decision
      redirect_to admin_reports_path, alert: t("trust.admin.notices.invalid_decision")
    end

    def missing_note
      redirect_to admin_reports_path, alert: t("trust.admin.notices.note_required")
    end
  end
end
