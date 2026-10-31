class AssignmentsController < ApplicationController
  rate_limit to: 10, within: 1.hour, only: :create, by: -> { current_user&.id },
    with: -> { redirect_to new_assignment_path, alert: t("workflow.errors.rate_limited") }

  before_action :require_verified_lawyer
  before_action :require_posting_access, only: %i[new create]
  before_action :set_assignment, only: %i[show cancel complete]
  before_action :require_assignment_visibility, only: :show
  before_action :require_assignment_manager, only: %i[cancel complete]

  def index
    @assignments = Assignment.accepting_proposals.includes(:firm, :proposals).ordered
    @assignments = @assignments.search(params[:q])
    @assignments = @assignments.where(kind: params[:kind]) if Assignment::KINDS.value?(params[:kind])
    @assignments = @assignments.where(city: params[:city]) if params[:city].present?
    @assignments = @assignments.where(practice_area: params[:practice_area]) if params[:practice_area].present?
    @cities = Assignment.accepting_proposals.distinct.order(:city).pluck(:city)
    @practice_areas = Assignment.accepting_proposals.distinct.order(:practice_area).pluck(:practice_area)
  end

  def show
    @owner_view = @assignment.owned_by?(current_user)
    @existing_proposal = @assignment.proposals.find_by(user: current_user)
    @proposal = @existing_proposal || @assignment.proposals.build
    @proposals = @owner_view ? @assignment.proposals.includes(:user, :firm).order(created_at: :desc) : Proposal.none
  end

  def new
    @assignment = current_firm.assignments.build(
      creator_user: current_user,
      kind: Assignment::KINDS[:court_replacement]
    )
  end

  def create
    @assignment = current_firm.assignments.build(assignment_params)
    @assignment.creator_user = current_user
    @assignment.status = "open"
    @assignment.urgent = false
    @assignment.content_rules_accepted_at = Time.current if content_rules_accepted?

    if @assignment.save
      @assignment.audit_events.create!(actor_user: current_user, firm: current_firm, action: "assignment.created")
      redirect_to @assignment, notice: t("notices.assignment_created")
    else
      render :new, status: :unprocessable_content
    end
  end

  def cancel
    @assignment.cancel!(actor: current_user)
    redirect_to dashboard_path, notice: t("workflow.notices.assignment_cancelled")
  rescue Assignment::InvalidTransition
    redirect_to @assignment, alert: t("workflow.errors.cannot_cancel_assignment")
  end

  def complete
    unless @assignment.status == "matched"
      return redirect_to @assignment, alert: t("workflow.errors.only_matched_can_complete")
    end

    @assignment.complete!(actor: current_user)
    redirect_to dashboard_path, notice: t("workflow.notices.assignment_completed")
  rescue Assignment::InvalidTransition
    redirect_to @assignment, alert: t("workflow.errors.only_matched_can_complete")
  end

  private

  def set_assignment
    @assignment = Assignment.includes(:firm, proposals: %i[user firm]).find(params[:id])
  end

  def require_assignment_manager
    return if @assignment.manageable_by?(current_user)

    redirect_to assignments_path, alert: t("workflow.errors.owner_only")
  end

  def require_assignment_visibility
    return if @assignment.visible_to?(current_user)

    redirect_to assignments_path, alert: t("workflow.errors.assignment_not_available")
  end

  def assignment_params
    attributes = params.require(:assignment).permit(
      :kind, :title, :description, :court, :court_selection, :court_other, :city, :starts_at,
      :duration_minutes, :practice_area, :practice_area_other, :fee_cents, :languages,
      :assignment_subtype, :response_deadline_at, :scope_indication, :delivery_due_at
    )
    attributes.delete(:practice_area_other) unless attributes[:practice_area] == Assignment::OTHER_CHOICE
    attributes.delete(:assignment_subtype) unless attributes[:kind] == Assignment::KINDS[:legal_task]
    attributes[:fee_cents] = euros_to_cents(attributes[:fee_cents])
    attributes
  end

  def content_rules_accepted?
    ActiveModel::Type::Boolean.new.cast(params.dig(:assignment, :content_rules_accepted))
  end

  def euros_to_cents(value)
    return nil if value.blank?

    amount = BigDecimal(value.to_s.tr(",", "."))
    return value unless amount.finite?

    cents = amount * 100
    return cents.to_s if !cents.finite? || cents.abs > (2**63) - 1

    cents.round.to_i
  rescue ArgumentError, FloatDomainError, RangeError
    value
  end
end
