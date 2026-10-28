class PrivacyRequestsController < ApplicationController
  rate_limit to: 5, within: 1.day, only: :create, by: -> { current_user&.id },
    with: -> { redirect_to privacy_requests_path, alert: t("trust.privacy_requests.notices.rate_limited") }

  def index
    @privacy_requests = current_user.privacy_requests.order(created_at: :desc)
  end

  def new
    @privacy_request = current_user.privacy_requests.build
  end

  def create
    @privacy_request = current_user.privacy_requests.build(privacy_request_params)
    if @privacy_request.save
      @privacy_request.audit_events.create!(
        actor_user: current_user,
        firm: current_firm,
        action: "privacy_request.created",
        metadata: { kind: @privacy_request.kind }
      )
      redirect_to privacy_requests_path, notice: t("trust.privacy_requests.notices.created")
    else
      render :new, status: :unprocessable_content
    end
  end

  private

  def privacy_request_params
    params.require(:privacy_request).permit(:kind, :details)
  end
end
