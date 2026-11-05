class DashboardController < ApplicationController
  PROPOSALS_PER_PAGE = 10

  before_action :require_verified_lawyer

  def index
    @assignments = current_firm.assignments.includes(:proposals).order(created_at: :desc)
    @open_assignments = @assignments.open
    accepted_assignment_ids = current_user.proposals.where(status: "accepted").select(:assignment_id)
    related_assignments = Assignment.where(firm_id: current_firm.id).or(Assignment.where(id: accepted_assignment_ids))
    @next_assignment_at = related_assignments.where(kind: Assignment::KINDS.fetch(:court_replacement))
      .active.upcoming.minimum(:starts_at)
    @proposal_count = current_user.proposals.count
    @proposal_total_pages = [ (@proposal_count + PROPOSALS_PER_PAGE - 1) / PROPOSALS_PER_PAGE, 1 ].max
    @proposal_page = (Integer(params[:proposal_page], exception: false) || 1).clamp(1, @proposal_total_pages)
    @recent_proposals = current_user.proposals.includes(:assignment).order(created_at: :desc, id: :desc)
      .offset((@proposal_page - 1) * PROPOSALS_PER_PAGE).limit(PROPOSALS_PER_PAGE)
    @notifications = current_user.notifications.unread.includes(:subject).order(created_at: :desc).limit(5)
    @suggested_assignments = Matching::AssignmentSuggestions.new(user: current_user).call
  end
end
