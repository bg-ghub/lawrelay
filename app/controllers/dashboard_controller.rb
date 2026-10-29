class DashboardController < ApplicationController
  before_action :require_verified_lawyer

  def index
    @assignments = current_firm.assignments.includes(:proposals).order(created_at: :desc)
    @open_assignments = @assignments.open
    @next_assignment_at = current_firm.assignments.active.upcoming.minimum(:starts_at)
    @recent_proposals = current_user.proposals.includes(:assignment).order(created_at: :desc).limit(5)
    @notifications = current_user.notifications.unread.includes(:subject).order(created_at: :desc).limit(5)
    @suggested_assignments = Matching::AssignmentSuggestions.new(user: current_user).call
  end
end
