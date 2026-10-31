class EmailAccessRequestsController < ApplicationController
  before_action :require_member
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  rate_limit to: 3, within: 1.hour, only: :create, by: -> { current_user&.id },
    with: -> { redirect_to email_access_request_path, alert: t("email_access.errors.rate_limited") }

  def new
    profile = current_user.lawyer_profile
    @email_address = current_user.email_address if profile&.directory_matched? &&
      !profile.directory_email.to_s.casecmp?(current_user.email_address)
  end

  def create
    @email_address = params.dig(:email_access, :email_address)
    result = Accounts::RequestEmailAccess.call(user: current_user, current_session: Current.session,
      password: params.dig(:email_access, :current_password), email_address: @email_address)
    unless result.success?
      @errors = result.errors
      return render :new, status: :unprocessable_content
    end

    delivery_ready = true
    if result.request_created
      delivery_ready = Onboarding::Delivery.request(result.user, email: !result.user.email_verified?, directory: true)
    end
    redirect_to verification_status_path, notice: t("email_access.notices.requested"),
      alert: (t("auth.verification_status.queue_unavailable") unless delivery_ready)
  end

  private

  def require_member
    head :forbidden if current_user.system_admin?
  end
end
