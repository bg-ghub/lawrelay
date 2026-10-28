class ReportsController < ApplicationController
  before_action :require_verified_lawyer
  before_action :set_assignment
  before_action :reject_own_assignment
  rate_limit to: 10, within: 1.day, only: :create, by: -> { current_user&.id },
    with: -> { redirect_to assignments_path, alert: t("trust.reports.notices.rate_limited") }

  def new
    @report = current_user.submitted_reports.build(reportable: @assignment)
  end

  def create
    @report = current_user.submitted_reports.build(report_params.merge(reportable: @assignment))
    if @report.save
      @report.audit_events.create!(
        actor_user: current_user,
        firm: current_firm,
        action: "report.created",
        metadata: { category: @report.category }
      )
      redirect_to @assignment, notice: t("trust.reports.notices.created")
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def set_assignment
    @assignment = Assignment.find(params[:assignment_id])
    return if @assignment.visible_to?(current_user)

    redirect_to assignments_path, alert: t("workflow.errors.assignment_not_available")
  end

  def reject_own_assignment
    return unless @assignment&.owned_by?(current_user)

    redirect_to @assignment, alert: t("trust.reports.errors.own_assignment")
  end

  def report_params
    params.require(:report).permit(:category, :details)
  end
end
