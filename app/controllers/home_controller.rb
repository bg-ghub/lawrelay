class HomeController < ApplicationController
  allow_unauthenticated_access

  def index
    @featured_assignments = if authenticated? && current_user.marketplace_verified?
      Assignment.open.upcoming.ordered.includes(:proposals).limit(3)
    else
      Assignment.none
    end
  end
end
