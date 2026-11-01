class TravelEstimateJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "osrm-routing", duration: 30.seconds

  def perform(proposal_id)
    proposal = Proposal.includes(:assignment, user: [ :lawyer_profile, :firms ]).find_by(id: proposal_id)
    return unless proposal

    Travel::Estimate.compute(proposal:)
  end
end
