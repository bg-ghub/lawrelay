class HomeController < ApplicationController
  allow_unauthenticated_access

  def index
    @featured_assignments = if authenticated? && current_user.marketplace_verified? &&
      (!current_user.two_factor_enabled? || Current.session.two_factor_verified?)
      Assignment.accepting_proposals.ordered.includes(:proposals).limit(3)
    else
      Assignment.none
    end
  end
end
