class EmailChangesController < ApplicationController
  rate_limit to: 3, within: 1.hour, only: :create, by: -> { current_user&.id },
    with: -> { redirect_to email_change_path, alert: t("email_change.errors.rate_limited") }

  before_action :require_member_account

  def new
    @email_address = current_user.email_address
  end

  def create
    @email_address = params.dig(:email_change, :email_address)
    result = Accounts::ChangeEmail.call(
      user: current_user,
      current_session: Current.session,
      password: params.dig(:email_change, :current_password),
      email_address: @email_address
    )

    unless result.success?
      @errors = result.errors
      return render :new, status: :unprocessable_content
    end

    EmailVerificationMailer.verify(result.user).deliver_later
    profile = result.profile
    if profile&.directory_profile_url.present? && !profile.verification_status.in?(%w[rejected suspended])
      Directory::VerificationJob.perform_later(result.user.id)
    end
    destination = result.user.system_admin? ? admin_users_path(locale: result.user.locale) : verification_status_path(locale: result.user.locale)
    redirect_to destination, notice: t("email_change.notices.sent")
  end

  private

  def require_member_account
    head :forbidden if current_user.system_admin?
  end
end
