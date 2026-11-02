class AccountDeletionsController < ApplicationController
  before_action :require_member
  before_action :load_deletion_request
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  rate_limit to: 3, within: 1.hour, only: %i[destroy cancel], by: -> { current_user.id },
    with: -> { redirect_to account_deletion_path, alert: t("account_deletion.notices.rate_limited") }

  def show
  end

  def destroy
    return redirect_to account_deletion_path if current_user.deletion_pending?

    unless params[:confirm_delete_account] == "1"
      flash.now[:alert] = t("account_deletion.notices.confirmation_required")
      return render :show, status: :unprocessable_content
    end

    Accounts::Deletion.schedule!(user: current_user, current_session: Current.session, password: params[:current_password])
    sign_out_member
    redirect_to new_session_path, notice: t("account_deletion.notices.scheduled"), status: :see_other
  rescue Accounts::Deletion::InvalidPassword
    invalid_password
  rescue Accounts::Deletion::InvalidSession
    reject_revoked_session
  rescue Accounts::Deletion::Unavailable
    unavailable
  rescue Privacy::AccountErasure::ProtectedAccount => error
    flash.now[:alert] = protection_message(error)
    render :show, status: :unprocessable_content
  end

  def cancel
    Accounts::Deletion.cancel!(user: current_user, current_session: Current.session, password: params[:current_password])
    sign_out_member
    redirect_to new_session_path, notice: t("account_deletion.notices.cancelled"), status: :see_other
  rescue Accounts::Deletion::InvalidPassword
    invalid_password
  rescue Accounts::Deletion::InvalidSession
    reject_revoked_session
  rescue Accounts::Deletion::Unavailable
    unavailable
  end

  private

  def require_member
    head :forbidden if current_user.system_admin?
  end

  def load_deletion_request
    @deletion_request = AccountDeletionRequest.find_by(id: current_user.deletion_request_id, user_id: current_user.id) if current_user.deletion_pending?
  end

  def invalid_password
    flash.now[:alert] = t("account_deletion.notices.invalid_password")
    render :show, status: :unprocessable_content
  end

  def unavailable
    flash.now[:alert] = t("account_deletion.notices.unavailable")
    render :show, status: :service_unavailable
  end

  def reject_revoked_session
    sign_out_member
    redirect_to new_session_path, alert: t("auth.sessions.invalid"), status: :see_other
  end

  def sign_out_member
    Current.session = nil
    cookies.delete(:session_id)
    reset_session
  end

  def protection_message(error)
    return t("account_deletion.notices.open_work") if error.message.include?("ongoing assignments and proposals")
    return t("account_deletion.notices.held") if error.message.include?("hold")
    return t("account_deletion.notices.billing") if error.message.include?("billing evidence")

    t("account_deletion.notices.blocked")
  end
end
