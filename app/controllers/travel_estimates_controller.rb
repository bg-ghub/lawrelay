class TravelEstimatesController < ApplicationController
  before_action :require_verified_lawyer
  rate_limit to: 60, within: 1.minute, by: -> { current_user&.id }, with: -> { head :too_many_requests }

  def show
    assignment = Assignment.find(params[:assignment_id])
    proposal = assignment.proposals.includes(user: [ :lawyer_profile, :firms ]).find(params[:proposal_id])
    unless assignment.owned_by?(current_user) || proposal.owned_by?(current_user)
      raise ActiveRecord::RecordNotFound
    end

    estimate = Travel::Estimate.call(proposal:)
    response.headers["Cache-Control"] = "private, no-store"
    render json: { status: estimate.status, text: helpers.travel_estimate_text(estimate) }
  end
end
